defmodule Nex.Agent.SandboxApprovalTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.App.Bus
  alias Nex.Agent.Sandbox.Approval
  alias Nex.Agent.Sandbox.Approval.Request
  alias Nex.Agent.Sandbox.PermissionRule
  alias Nex.Agent.Sandbox.PermissionRuleStore

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-approval-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    server = String.to_atom("approval_test_#{System.unique_integer([:positive])}")
    start_supervised!({Approval, name: server})

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace, server: server}
  end

  test "approves one pending request without creating grants", %{
    workspace: workspace,
    server: server
  } do
    request = request(workspace, grant_key: "command:execute:exact:once")
    task = Task.async(fn -> Approval.request(request, server: server) end)

    wait_for(fn -> Approval.pending?(workspace, "feishu:chat", server: server) end)

    assert {:ok, %{approved: 1, granted: nil, choice: :once}} =
             Approval.approve(workspace, "feishu:chat", :once, server: server)

    assert Task.await(task) == {:ok, :approved}
    refute Approval.approved?(workspace, "feishu:chat", request, server: server)
  end

  test "session path rule suppresses repeated path request in the same session", %{
    workspace: workspace,
    server: server
  } do
    path = Path.join([workspace, "notes", "a.md"])
    request = path_request(workspace, subject: path)
    task = Task.async(fn -> Approval.request(request, server: server) end)

    wait_for(fn -> Approval.pending?(workspace, "feishu:chat", server: server) end)

    assert {:ok, %{approved: 1, granted: %{"scope" => "session"}}} =
             Approval.approve(workspace, "feishu:chat", :session, server: server)

    assert Task.await(task) == {:ok, :approved}
    assert Approval.approved?(workspace, "feishu:chat", request, server: server)
    assert Approval.request(request, server: server) == {:ok, :approved}
  end

  test "similar path rule allows sibling paths under the same directory", %{
    workspace: workspace,
    server: server
  } do
    first_path = Path.join([workspace, "notes", "a.md"])
    second_path = Path.join([workspace, "notes", "b.md"])

    request =
      path_request(workspace, subject: first_path)

    task = Task.async(fn -> Approval.request(request, server: server) end)
    wait_for(fn -> Approval.pending?(workspace, "feishu:chat", server: server) end)

    assert {:ok, %{approved: 1, granted: %{"kind" => "permission_rule"}}} =
             Approval.approve(workspace, "feishu:chat", :similar, server: server)

    assert Task.await(task) == {:ok, :approved}

    follow_up = path_request(workspace, subject: second_path)

    assert Approval.request(follow_up, server: server) == {:ok, :approved}
  end

  test "legacy command grant options are not accepted as durable rules", %{
    workspace: workspace,
    server: server
  } do
    request =
      request(workspace,
        grant_key: "command:execute:escalated:abc",
        metadata: %{"sandbox_permissions" => "require_escalated"},
        grant_options: [
          %{
            "level" => "exact",
            "grant_key" => "command:execute:escalated:abc",
            "subject" => "npm install"
          },
          %{
            "level" => "similar",
            "grant_key" => "legacy-command-family:npm:install",
            "subject" => "npm install"
          }
        ]
      )

    task = Task.async(fn -> Approval.request(request, server: server) end)
    wait_for(fn -> Approval.pending?(workspace, "feishu:chat", server: server) end)

    assert {:error, :permission_approval_requires_rule} =
             Approval.approve(workspace, "feishu:chat", :session, server: server)

    assert {:error, :permission_approval_requires_rule} =
             Approval.approve(workspace, "feishu:chat", :always, server: server)

    assert {:error, :permission_approval_requires_rule} =
             Approval.approve(workspace, "feishu:chat", :similar, server: server)

    assert {:ok, %{approved: 1, choice: :once}} =
             Approval.approve(workspace, "feishu:chat", :once, server: server)

    assert Task.await(task) == {:ok, :approved}
  end

  test "request id approval resolves the selected pending request only", %{
    workspace: workspace,
    server: server
  } do
    first = request(workspace, id: "approval_first", grant_key: "command:execute:exact:first")
    second = request(workspace, id: "approval_second", grant_key: "command:execute:exact:second")

    first_task = Task.async(fn -> Approval.request(first, server: server, publish?: false) end)
    second_task = Task.async(fn -> Approval.request(second, server: server, publish?: false) end)

    wait_for(fn -> length(Approval.pending(workspace, "feishu:chat", server: server)) == 2 end)

    assert {:ok, %{approved: 1, request_id: "approval_second"}} =
             Approval.approve_request("approval_second", :once, server: server)

    assert Task.await(second_task) == {:ok, :approved}
    assert Task.yield(first_task, 50) == nil
    assert [%{id: "approval_first"}] = Approval.pending(workspace, "feishu:chat", server: server)

    assert {:ok, %{denied: 1, request_id: "approval_first"}} =
             Approval.deny_request("approval_first", :once, server: server)

    assert Task.await(first_task) == {:error, :denied}
  end

  test "pending callback runs after request is addressable by id", %{
    workspace: workspace,
    server: server
  } do
    parent = self()
    request = request(workspace, id: "approval_on_pending", grant_key: "command:execute:exact:cb")

    task =
      Task.async(fn ->
        Approval.request(request,
          server: server,
          publish?: false,
          on_pending: fn pending -> send(parent, {:on_pending, pending.id}) end
        )
      end)

    assert_receive {:on_pending, "approval_on_pending"}

    assert [%{id: "approval_on_pending"}] =
             Approval.pending(workspace, "feishu:chat", server: server)

    assert {:ok, %{approved: 1, request_id: "approval_on_pending"}} =
             Approval.approve_request("approval_on_pending", :once, server: server)

    assert Task.await(task) == {:ok, :approved}
  end

  test "grant approval sweeps matching pending requests and emits per-request events", %{
    workspace: workspace,
    server: server
  } do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    Bus.subscribe(:sandbox_approval_resolved)

    first_path = Path.join([workspace, "notes", "first.md"])
    second_path = Path.join([workspace, "notes", "second.md"])

    first =
      path_request(workspace,
        id: "approval_grant_first",
        subject: first_path
      )

    second =
      path_request(workspace,
        id: "approval_grant_second",
        subject: second_path
      )

    first_task = Task.async(fn -> Approval.request(first, server: server, publish?: false) end)
    second_task = Task.async(fn -> Approval.request(second, server: server, publish?: false) end)

    wait_for(fn -> length(Approval.pending(workspace, "feishu:chat", server: server)) == 2 end)

    assert {:ok, %{approved: 2, request_id: "approval_grant_first", swept: swept}} =
             Approval.approve_request("approval_grant_first", :similar, server: server)

    assert swept == ["approval_grant_second"]
    assert Task.await(first_task) == {:ok, :approved}
    assert Task.await(second_task) == {:ok, :approved}
    assert Approval.pending(workspace, "feishu:chat", server: server) == []

    assert_receive {:bus_message, :sandbox_approval_resolved, first_event}
    assert_receive {:bus_message, :sandbox_approval_resolved, second_event}

    events_by_id = Map.new([first_event, second_event], &{&1.request_id, &1})
    assert events_by_id["approval_grant_first"].choice == :similar
    assert events_by_id["approval_grant_second"].choice == :grant
  end

  test "always grant persists to workspace and loads in a new approval server", %{
    workspace: workspace,
    server: server
  } do
    request = path_request(workspace, subject: Path.join([workspace, "notes", "a.md"]))
    task = Task.async(fn -> Approval.request(request, server: server) end)
    wait_for(fn -> Approval.pending?(workspace, "feishu:chat", server: server) end)

    assert {:ok, %{approved: 1, granted: %{"scope" => "always"}}} =
             Approval.approve(workspace, "feishu:chat", :always, server: server)

    assert Task.await(task) == {:ok, :approved}

    paths = PermissionRuleStore.paths(workspace)
    assert File.exists?(paths.chain)
    assert File.exists?(paths.manifest)

    next_server = String.to_atom("approval_reload_#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: next_server,
      start: {Approval, :start_link, [[name: next_server]]}
    })

    assert Approval.approved?(workspace, "feishu:chat", request, server: next_server)
    assert Approval.request(request, server: next_server) == {:ok, :approved}
  end

  test "command always approval persists and reloads through permission rules", %{
    workspace: workspace,
    server: server
  } do
    event = %{
      channel: "discord",
      chat_id: "thread-1",
      workspace: workspace,
      command: "dokobot get https://example.com/a",
      requested_execution: :sandboxed
    }

    request =
      request(workspace,
        session_key: "discord:thread-1",
        channel: "discord",
        chat_id: "thread-1",
        subject: event.command,
        grant_options: PermissionRule.grant_options(event)
      )

    task = Task.async(fn -> Approval.request(request, server: server) end)
    wait_for(fn -> Approval.pending?(workspace, "discord:thread-1", server: server) end)

    assert {:ok, %{approved: 1, granted: %{"scope" => "always"}}} =
             Approval.approve(workspace, "discord:thread-1", :always, server: server)

    assert Task.await(task) == {:ok, :approved}

    paths = PermissionRuleStore.paths(workspace)
    assert File.exists?(paths.chain)
    assert File.exists?(paths.manifest)

    refute File.exists?(Path.join([workspace, "permissions", "grants.json"]))

    next_server = String.to_atom("approval_rule_reload_#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: next_server,
      start: {Approval, :start_link, [[name: next_server]]}
    })

    follow_up =
      request(workspace,
        session_key: "discord:thread-1",
        channel: "discord",
        chat_id: "thread-1",
        subject: event.command,
        grant_options: PermissionRule.grant_options(event)
      )

    assert Approval.approved?(workspace, "discord:thread-1", follow_up, server: next_server)
    assert Approval.request(follow_up, server: next_server) == {:ok, :approved}
  end

  test "deny and reset resolve pending callers", %{workspace: workspace, server: server} do
    denied = request(workspace, grant_key: "command:execute:exact:deny")
    denied_task = Task.async(fn -> Approval.request(denied, server: server) end)
    wait_for(fn -> Approval.pending?(workspace, "feishu:chat", server: server) end)

    assert {:ok, %{denied: 1}} = Approval.deny(workspace, "feishu:chat", :once, server: server)
    assert Task.await(denied_task) == {:error, :denied}

    cancelled = request(workspace, grant_key: "command:execute:exact:cancel")
    cancelled_task = Task.async(fn -> Approval.request(cancelled, server: server) end)
    wait_for(fn -> Approval.pending?(workspace, "feishu:chat", server: server) end)

    assert {:ok, %{cancelled: 1}} =
             Approval.reset_session(workspace, "feishu:chat", :new, server: server)

    assert Task.await(cancelled_task) == {:error, {:cancelled, :new}}
  end

  defp request(workspace, attrs) do
    attrs =
      Keyword.merge(
        [
          workspace: workspace,
          session_key: "feishu:chat",
          channel: "feishu_test",
          chat_id: "chat",
          kind: :command,
          operation: :execute,
          subject: "git status",
          description: "run git status"
        ],
        attrs
      )

    Request.new(attrs)
  end

  defp path_request(workspace, attrs) do
    channel = Keyword.get(attrs, :channel, "feishu_test")
    chat_id = Keyword.get(attrs, :chat_id, "chat")
    operation = Keyword.get(attrs, :operation, :read)
    subject = Keyword.get(attrs, :subject, Path.join(workspace, "notes"))

    rule_options =
      PermissionRule.grant_options(%{
        tool_name: "filesystem",
        params: %{"path" => subject, "operation" => operation},
        workspace: workspace,
        channel: channel,
        chat_id: chat_id
      })

    attrs =
      Keyword.merge(
        [
          workspace: workspace,
          session_key: "feishu:chat",
          channel: channel,
          chat_id: chat_id,
          kind: :path,
          operation: operation,
          subject: subject,
          description: "read #{subject}",
          grant_key: rule_options |> List.first(%{}) |> Map.get("grant_key", ""),
          grant_options: rule_options
        ],
        attrs
      )

    Request.new(attrs)
  end

  defp wait_for(fun, attempts \\ 20)

  defp wait_for(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_for(fun, attempts - 1)
    end
  end

  defp wait_for(_fun, 0), do: flunk("condition did not become true")
end
