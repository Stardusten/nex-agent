defmodule Nex.Agent.RunControlTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.ControlPlane.{Gauge, Query}
  alias Nex.Agent.RunControl

  setup do
    server = String.to_atom("run_control_test_#{System.unique_integer([:positive])}")
    start_supervised!({RunControl, name: server})

    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-run-control-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(workspace) end)

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

  test "owner lifecycle writes observations and workspace current gauge", %{
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

    assert [started] = observations(workspace, "run.owner.started")
    assert started["context"]["run_id"] == run.id

    assert :ok = RunControl.set_phase(run.id, :streaming, server: server)
    assert :ok = RunControl.set_queued_count(run.id, 2, server: server)
    assert :ok = RunControl.append_tool_output(run.id, "bash", "token=secret\nok", server: server)
    assert :ok = RunControl.append_assistant_partial(run.id, "working", server: server)

    assert [_ | _] = observations(workspace, "run.owner.updated")

    assert %{"value" => %{"owners" => [owner]}} =
             Gauge.current("run.owner.current", workspace: workspace)

    assert owner["run_id"] == run.id
    assert owner["phase"] == "llm"
    assert owner["current_tool"] == "bash"
    assert owner["queued_count"] == 2
    assert owner["latest_assistant_partial_tail"] =~ "working"
    assert owner["latest_tool_output_tail"] =~ "[REDACTED]"
    refute inspect(owner) =~ "secret"

    assert :ok = RunControl.finish_owner(run.id, :ok, server: server)

    assert [finished] = observations(workspace, "run.owner.finished")
    assert finished["context"]["run_id"] == run.id

    assert %{"value" => %{"owners" => []}} =
             Gauge.current("run.owner.current", workspace: workspace)
  end

  test "workspace gauge contains all active owner sessions and removes failed/cancelled runs", %{
    server: server,
    workspace: workspace
  } do
    assert {:ok, run_a} = RunControl.start_owner(workspace, "feishu:a", %{}, server: server)
    assert {:ok, run_b} = RunControl.start_owner(workspace, "feishu:b", %{}, server: server)

    assert %{"value" => %{"owners" => owners}} =
             Gauge.current("run.owner.current", workspace: workspace)

    assert Enum.map(owners, & &1["run_id"]) == [run_a.id, run_b.id]

    assert :ok = RunControl.fail_owner(run_a.id, :boom, server: server)

    assert {:ok, %{cancelled?: true, run_id: run_b_id}} =
             RunControl.cancel_owner(workspace, "feishu:b", :user_stop, server: server)

    assert run_b_id == run_b.id
    assert [failed] = observations(workspace, "run.owner.failed")
    assert failed["attrs"]["reason_type"] == "boom"
    assert [cancelled] = observations(workspace, "run.owner.cancelled")
    assert cancelled["context"]["run_id"] == run_b.id

    assert %{"value" => %{"owners" => []}} =
             Gauge.current("run.owner.current", workspace: workspace)
  end

  test "stale owner result writes stale_result observation in the original workspace", %{
    server: server,
    workspace: workspace,
    session_key: session_key
  } do
    assert {:ok, run} = RunControl.start_owner(workspace, session_key, %{}, server: server)
    assert :ok = RunControl.finish_owner(run.id, :ok, server: server)

    assert {:error, :stale} = RunControl.finish_owner(run.id, :late, server: server)

    assert [stale] = observations(workspace, "run.owner.stale_result")
    assert stale["context"]["run_id"] == run.id
    assert stale["context"]["session_key"] == session_key
    assert stale["attrs"]["operation"] == "finish"
  end

  defp observations(workspace, tag) do
    Query.query(%{"tag" => tag}, workspace: workspace)
  end
end
