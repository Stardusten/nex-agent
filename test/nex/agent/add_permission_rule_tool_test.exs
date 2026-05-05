defmodule Nex.Agent.AddPermissionRuleToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Capability.Tool.Core.AddPermissionRule
  alias Nex.Agent.Interface.Outbound.Approval, as: OutboundApproval
  alias Nex.Agent.Sandbox.{Approval, PermissionRule, PermissionRuleStore}

  test "path_under proposal requires rule approval and stores durable thread rule" do
    workspace = tmp_dir("workspace")
    root = tmp_dir("desktop")
    file = Path.join(root, "note.md")
    approval_server = Module.concat(__MODULE__, :"Approval#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.mkdir_p!(root)
    File.write!(file, "hello\n")
    start_supervised!({Approval, name: approval_server})

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(root)
    end)

    ctx = %{
      workspace: workspace,
      cwd: workspace,
      session_key: "discord:thread-1",
      channel: "discord",
      chat_id: "thread-1",
      approval_server: approval_server
    }

    task =
      Task.async(fn ->
        AddPermissionRule.execute(
          %{
            "resource" => "path",
            "path_under" => root,
            "operations" => ["read", "list"],
            "scope" => "thread",
            "persistence" => "always",
            "reason" => "Need to inspect Desktop project files in this thread"
          },
          ctx
        )
      end)

    wait_until(fn ->
      Approval.pending?(workspace, "discord:thread-1", server: approval_server)
    end)

    [request] = Approval.pending(workspace, "discord:thread-1", server: approval_server)

    action_ids = request |> OutboundApproval.actions() |> Enum.map(& &1["id"])
    refute "approve_once" in action_ids
    assert "approve_always" in action_ids
    assert "deny_once" in action_ids

    assert {:ok, %{approved: 0, skipped_rule_required: 1, choice: :all}} =
             Approval.approve(workspace, "discord:thread-1", :all, server: approval_server)

    assert Approval.pending?(workspace, "discord:thread-1", server: approval_server)

    assert {:ok, %{approved: 1, choice: :always}} =
             Approval.approve(workspace, "discord:thread-1", :always, server: approval_server)

    assert {:ok, %{status: :approved, persistence: "always", subject: subject}} =
             Task.await(task, 1_000)

    assert subject =~ "Allow read/list under"

    assert {:ok, rules} = PermissionRuleStore.load(workspace)

    allowed =
      PermissionRule.decide(
        %{
          tool_name: "filesystem",
          params: %{"path" => file, "operation" => "read"},
          workspace: workspace,
          cwd: workspace,
          channel: "discord",
          chat_id: "thread-1"
        },
        rules
      )

    assert allowed.action == :allow

    bash_decision =
      PermissionRule.decide(
        %{
          tool_name: "bash",
          params: %{"command" => "ls #{root}"},
          workspace: workspace,
          cwd: workspace,
          channel: "discord",
          chat_id: "thread-1"
        },
        rules
      )

    assert bash_decision.action == :ask

    assert Enum.any?(
             bash_decision.requirement_decisions,
             &(&1.requirement.resource == :command and &1.action == :ask)
           )

    other_thread =
      PermissionRule.decide(
        %{
          tool_name: "filesystem",
          params: %{"path" => file, "operation" => "read"},
          workspace: workspace,
          cwd: workspace,
          channel: "discord",
          chat_id: "thread-2"
        },
        rules
      )

    assert other_thread.action == :ask
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition was not met")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp tmp_dir(label) do
    Path.join(
      System.tmp_dir!(),
      "nex-agent-rule-tool-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
