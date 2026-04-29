defmodule Nex.Agent.Conversation.FollowUpTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.{Conversation.FollowUp, Conversation.RunControl}

  test "busy prompt requires observe for status and incident questions" do
    run = %RunControl.Run{
      id: "run_follow_up",
      workspace: "/tmp/nex-follow-up",
      session_key: "feishu:chat-1",
      channel: "feishu",
      chat_id: "chat-1",
      status: :running,
      kind: :owner,
      started_at_ms: System.system_time(:millisecond),
      updated_at_ms: System.system_time(:millisecond),
      current_phase: :tool,
      current_tool: "bash",
      latest_tool_output_tail: "still running",
      latest_assistant_partial: "working",
      queued_count: 1,
      cancel_ref: make_ref()
    }

    prompt =
      FollowUp.prompt(run, "后台报错了吗？",
        mode: :busy,
        workspace: "/tmp/nex-follow-up",
        session_key: "feishu:chat-1"
      )

    assert prompt =~ "use `observe` before answering"
    assert prompt =~ "Do not infer that there are no errors from the owner snapshot alone"
    assert prompt =~ "Workspace: /tmp/nex-follow-up"
    assert prompt =~ "Session key: feishu:chat-1"
    assert prompt =~ "Owner run id: run_follow_up"
    assert prompt =~ "`observe` action `summary`"
    assert prompt =~ "`observe` action `incident` with `run_id: \"run_follow_up\"`"
    assert prompt =~ "`observe` action `query` with `session_key: \"feishu:chat-1\"`"
  end

  test "idle prompt can inspect evidence without inventing an active owner run" do
    prompt =
      FollowUp.prompt(nil, "看下最近日志",
        mode: :idle,
        workspace: "/tmp/nex-follow-up",
        session_key: "feishu:chat-2"
      )

    assert prompt =~ "There is no current owner run."
    assert prompt =~ "use `observe` before answering"
    assert prompt =~ "do not invent an active owner run"
    assert prompt =~ "`observe` action `summary`"
    assert prompt =~ "`observe` action `query` with `session_key: \"feishu:chat-2\"`"
  end

  test "follow-up tool surface stays read-only plus interrupt" do
    allowed = [
      "executor_status",
      "find",
      "memory_status",
      "observe",
      "read",
      "skill_get",
      "interrupt_session",
      "tool_list",
      "web_fetch",
      "web_search"
    ]

    for name <- allowed do
      assert FollowUp.allowed_tool_definition?(%{"name" => name})
    end

    for name <- ["self_update", "apply_patch", "bash", "message"] do
      refute FollowUp.allowed_tool_definition?(%{"name" => name})
    end
  end
end
