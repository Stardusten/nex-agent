defmodule Nex.Agent.RunControlTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.RunControl

  setup do
    server = String.to_atom("run_control_test_#{System.unique_integer([:positive])}")
    start_supervised!({RunControl, name: server})

    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-run-control-#{System.unique_integer([:positive])}")

    {:ok, server: server, workspace: workspace, session_key: "feishu:chat-1"}
  end

  test "start_owner exposes a busy snapshot and rejects a second owner", %{
    server: server,
    workspace: workspace,
    session_key: session_key
  } do
    assert {:ok, run} =
             RunControl.start_owner(
               workspace,
               session_key,
               [channel: "feishu", chat_id: "chat-1"],
               server: server
             )

    assert run.workspace == Path.expand(workspace)
    assert run.session_key == session_key
    assert run.channel == "feishu"
    assert run.chat_id == "chat-1"
    assert run.status == :running
    assert run.current_phase == :starting
    assert run.kind == :owner
    assert is_reference(run.cancel_ref)

    assert {:ok, snapshot} = RunControl.owner_snapshot(workspace, session_key, server: server)
    assert snapshot.id == run.id

    assert {:error, :already_running} =
             RunControl.start_owner(workspace, session_key, %{}, server: server)
  end

  test "tool output, assistant partial, phase and queue count update the owner snapshot", %{
    server: server,
    workspace: workspace,
    session_key: session_key
  } do
    assert {:ok, run} = RunControl.start_owner(workspace, session_key, %{}, server: server)
    assert :ok = RunControl.set_phase(run.id, :streaming, server: server)
    assert :ok = RunControl.set_queued_count(run.id, 3, server: server)
    assert :ok = RunControl.append_tool_output(run.id, "bash", "line1\nline2", server: server)
    assert :ok = RunControl.append_assistant_partial(run.id, "still working", server: server)

    assert {:ok, snapshot} = RunControl.owner_snapshot(workspace, session_key, server: server)
    assert snapshot.current_phase == :llm
    assert snapshot.current_tool == "bash"
    assert snapshot.queued_count == 3
    assert snapshot.latest_tool_output_tail =~ "line2"
    assert snapshot.latest_assistant_partial =~ "still working"
  end

  test "finish clears the busy snapshot and stale finish is rejected after replacement", %{
    server: server,
    workspace: workspace,
    session_key: session_key
  } do
    assert {:ok, run} = RunControl.start_owner(workspace, session_key, %{}, server: server)
    assert :ok = RunControl.finish_owner(run.id, :ok, server: server)
    assert {:error, :idle} = RunControl.owner_snapshot(workspace, session_key, server: server)

    assert {:ok, old_run} = RunControl.start_owner(workspace, session_key, %{}, server: server)

    assert {:ok, %{cancelled?: true, run_id: old_run_id}} =
             RunControl.cancel_owner(workspace, session_key, :user_stop, server: server)

    assert old_run_id == old_run.id
    assert RunControl.cancelled?(old_run.cancel_ref, server: server)
    assert {:error, :idle} = RunControl.owner_snapshot(workspace, session_key, server: server)

    assert {:ok, new_run} = RunControl.start_owner(workspace, session_key, %{}, server: server)
    assert {:error, :stale} = RunControl.finish_owner(old_run.id, :ok, server: server)

    assert {:ok, snapshot} = RunControl.owner_snapshot(workspace, session_key, server: server)
    assert snapshot.id == new_run.id
  end

  test "cancel on an idle session is a no-op result", %{
    server: server,
    workspace: workspace,
    session_key: session_key
  } do
    assert {:ok, %{cancelled?: false, run_id: nil}} =
             RunControl.cancel_owner(workspace, session_key, :user_stop, server: server)
  end
end
