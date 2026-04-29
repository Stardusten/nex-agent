defmodule Nex.Agent.App.HeartbeatTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.App.Heartbeat

  setup do
    unique = System.unique_integer([:positive])
    workspace = Path.join(System.tmp_dir!(), "nex-agent-heartbeat-#{unique}")
    heartbeat_name = String.to_atom("heartbeat_test_#{unique}")

    File.mkdir_p!(Path.join(workspace, "sessions"))
    File.mkdir_p!(Path.join(workspace, "memory"))

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    start_supervised!({Heartbeat, name: heartbeat_name, workspace: workspace, interval: 3600})
    :ok = GenServer.call(heartbeat_name, :start)

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace, heartbeat_name: heartbeat_name}
  end

  test "heartbeat session GC removes stale session directories in the configured workspace", %{
    workspace: workspace,
    heartbeat_name: heartbeat_name
  } do
    session_dir = Path.join(workspace, "sessions/stale-session")
    File.mkdir_p!(session_dir)
    File.write!(Path.join(session_dir, "messages.jsonl"), "{}\n")
    File.touch(session_dir, {{2020, 1, 1}, {0, 0, 0}})

    trigger_maintenance(heartbeat_name)

    assert wait_until(fn -> not File.exists?(session_dir) end)
  end

  test "heartbeat archives stale daily logs in the configured workspace", %{
    workspace: workspace,
    heartbeat_name: heartbeat_name
  } do
    date_dir = Path.join(workspace, "memory/2020-01-01")
    log_file = Path.join(date_dir, "log.md")
    archive_file = Path.join(workspace, "memory/archive/2020-01.md")

    File.mkdir_p!(date_dir)
    File.write!(log_file, "archived content")

    trigger_maintenance(heartbeat_name)

    assert wait_until(fn -> File.exists?(archive_file) end)
    refute File.exists?(date_dir)
    assert File.read!(archive_file) =~ "# 2020-01-01"
    assert File.read!(archive_file) =~ "archived content"
  end

  test "heartbeat records weekly evolution failures in execution history", %{
    heartbeat_name: heartbeat_name
  } do
    completed_at = System.system_time(:second)
    send(heartbeat_name, {:weekly_evolution_done, completed_at, {:error, :llm_unavailable}})

    assert wait_until(fn ->
             state = :sys.get_state(heartbeat_name)

             Enum.any?(state.execution_history, fn
               {"evolution", _timestamp,
                %{trigger: "scheduled_weekly", result: {:error, _reason}}} ->
                 true

               _ ->
                 false
             end) and is_nil(state.last_weekly_evolution)
           end)
  end

  test "heartbeat advances weekly cooldown on weekly evolution success", %{
    heartbeat_name: heartbeat_name
  } do
    completed_at = System.system_time(:second)
    send(heartbeat_name, {:weekly_evolution_done, completed_at, {:ok, %{applied: 1}}})

    assert wait_until(fn ->
             state = :sys.get_state(heartbeat_name)

             state.last_weekly_evolution == completed_at and
               Enum.any?(state.execution_history, fn
                 {"evolution", ^completed_at, %{trigger: "scheduled_weekly", result: {:ok, _}}} ->
                   true

                 _ ->
                   false
               end)
           end)
  end

  defp trigger_maintenance(heartbeat_name) do
    send(Process.whereis(heartbeat_name), :tick)
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      wait_until(fun, attempts - 1)
    end
  end
end
