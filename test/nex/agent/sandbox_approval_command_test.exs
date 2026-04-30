defmodule Nex.Agent.SandboxApprovalCommandTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.App.Bus
  alias Nex.Agent.Conversation.InboundWorker
  alias Nex.Agent.Interface.Inbound.Envelope
  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Sandbox.Approval
  alias Nex.Agent.Sandbox.Approval.Request

  @channel "feishu_approval_test"
  @topic {:channel_outbound, @channel}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-approval-command-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    if Process.whereis(Approval) == nil do
      start_supervised!({Approval, name: Approval})
    end

    worker_name = String.to_atom("approval_command_worker_#{System.unique_integer([:positive])}")
    parent = self()

    prompt_fun = fn _agent, _prompt, _opts ->
      send(parent, :prompt_called)
      raise "approval commands must not enter llm"
    end

    start_supervised!(
      {InboundWorker, name: worker_name, config: config(), agent_prompt_fun: prompt_fun}
    )

    Bus.subscribe(@topic)

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace, worker_name: worker_name}
  end

  test "/approve session resolves pending request and creates session grant", %{
    workspace: workspace,
    worker_name: worker_name
  } do
    session_key = "#{@channel}:chat-approval"

    request =
      Request.new(
        workspace: workspace,
        session_key: session_key,
        channel: @channel,
        chat_id: "chat-approval",
        kind: :command,
        operation: :execute,
        subject: "git status",
        description: "run git status",
        grant_key: "command:execute:exact:approval-command"
      )

    task = Task.async(fn -> Approval.request(request) end)

    assert_receive {:bus_message, @topic, approval_payload}, 1_000
    assert approval_payload.content =~ "Approval required"

    send_command(worker_name, workspace, "chat-approval", "/approve session")

    assert_receive {:bus_message, @topic, result_payload}, 1_000
    assert result_payload.content =~ "Approved 1 pending request(s)"
    assert result_payload.content =~ "granted session permission"
    assert Task.await(task) == {:ok, :approved}
    assert Approval.approved?(workspace, session_key, request)
    refute_received :prompt_called
  end

  test "/approve all approves current pending requests without grants", %{
    workspace: workspace,
    worker_name: worker_name
  } do
    session_key = "#{@channel}:chat-approve-all"

    first =
      Request.new(
        workspace: workspace,
        session_key: session_key,
        channel: @channel,
        chat_id: "chat-approve-all",
        subject: "first",
        grant_key: "command:execute:exact:first"
      )

    second =
      Request.new(
        workspace: workspace,
        session_key: session_key,
        channel: @channel,
        chat_id: "chat-approve-all",
        subject: "second",
        grant_key: "command:execute:exact:second"
      )

    first_task = Task.async(fn -> Approval.request(first) end)
    second_task = Task.async(fn -> Approval.request(second) end)

    assert_receive {:bus_message, @topic, _approval_payload}, 1_000
    assert_receive {:bus_message, @topic, _approval_payload}, 1_000

    send_command(worker_name, workspace, "chat-approve-all", "/approve all")

    assert_receive {:bus_message, @topic, result_payload}, 1_000
    assert result_payload.content == "Approved 2 pending request(s)."
    assert Task.await(first_task) == {:ok, :approved}
    assert Task.await(second_task) == {:ok, :approved}
    refute Approval.approved?(workspace, session_key, first)
    refute Approval.approved?(workspace, session_key, second)
  end

  test "/deny all rejects current pending requests", %{
    workspace: workspace,
    worker_name: worker_name
  } do
    session_key = "#{@channel}:chat-deny-all"

    request =
      Request.new(
        workspace: workspace,
        session_key: session_key,
        channel: @channel,
        chat_id: "chat-deny-all",
        subject: "danger",
        grant_key: "command:execute:exact:danger"
      )

    task = Task.async(fn -> Approval.request(request) end)
    assert_receive {:bus_message, @topic, _approval_payload}, 1_000

    send_command(worker_name, workspace, "chat-deny-all", "/deny all")

    assert_receive {:bus_message, @topic, result_payload}, 1_000
    assert result_payload.content == "Denied 1 pending request(s)."
    assert Task.await(task) == {:error, :denied}
  end

  defp send_command(worker_name, workspace, chat_id, text) do
    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: @channel,
        chat_id: chat_id,
        sender_id: "tester",
        text: text,
        message_type: :text,
        raw: %{},
        metadata: %{"workspace" => workspace},
        media_refs: [],
        attachments: []
      }
    })
  end

  defp config do
    Config.from_map(%{
      "channel" => %{
        @channel => %{
          "type" => "feishu",
          "enabled" => true,
          "app_id" => "cli",
          "app_secret" => "secret"
        }
      },
      "tools" => %{}
    })
  end
end
