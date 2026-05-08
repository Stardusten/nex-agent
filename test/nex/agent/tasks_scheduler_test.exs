defmodule Nex.Agent.TasksSchedulerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.App.Bus
  alias Nex.Agent.Interface.Inbound.Envelope
  alias Nex.Agent.Tasks
  alias Nex.Agent.Tasks.Scheduler

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-tasks-scheduler-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    if Process.whereis(Tasks) == nil do
      start_supervised!({Tasks, name: Tasks})
    end

    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  test "normalizes schedules and calculates next run times" do
    now = epoch({{2026, 5, 8}, {8, 59, 0}})

    assert Scheduler.normalize_schedule(%{"type" => "every", "seconds" => "30"}) == %{
             type: :every,
             seconds: 30
           }

    assert Scheduler.next_run(%{"type" => "every", "seconds" => "30"}, 100) == 130
    assert Scheduler.next_run(%{"type" => "at", "timestamp" => "120"}, 100) == 120
    assert Scheduler.next_run(%{"type" => "at", "timestamp" => "90"}, 100) == nil

    assert Scheduler.next_run(%{"type" => "cron", "expr" => "0 9 * * *"}, now) ==
             epoch({{2026, 5, 8}, {9, 0, 0}})
  end

  test "detects due tasks from atom or string keyed state" do
    assert Scheduler.due?(%{enabled: true, next_run: 100}, 100)
    assert Scheduler.due?(%{"enabled" => true, "next_run" => 100}, 101)
    refute Scheduler.due?(%{enabled: false, next_run: 100}, 101)
    refute Scheduler.due?(%{enabled: true, next_run: 102}, 101)
  end

  test "scheduled task agent_turn action publishes the action message", %{workspace: workspace} do
    previous_subscribers = Bus.subscribers(:inbound)
    Enum.each(previous_subscribers, &Bus.unsubscribe(:inbound, &1))

    on_exit(fn ->
      Enum.each(previous_subscribers, fn pid ->
        if Process.alive?(pid), do: Bus.subscribe(:inbound, pid)
      end)
    end)

    Bus.subscribe(:inbound)

    assert {:ok, task} =
             Tasks.upsert(
               %{
                 id: "agent-turn-action",
                 name: "Agent turn action",
                 message: "fallback message",
                 action: %{"type" => "agent_turn", "message" => "action message"},
                 schedule: %{type: :every, seconds: 3600},
                 channel: "task-test",
                 chat_id: "chat-1"
               },
               workspace: workspace
             )

    assert {:ok, _updated} = Tasks.run_now(task.id, %{}, workspace: workspace)

    assert_receive {:bus_message, :inbound, %Envelope{} = envelope}, 1_000
    assert envelope.channel == "task-test"
    assert envelope.chat_id == "chat-1"
    assert envelope.text =~ "action message"
    refute envelope.text =~ "fallback message"
    assert envelope.metadata["_from_task"] == true
  end

  defp epoch(datetime) do
    :calendar.datetime_to_gregorian_seconds(datetime) -
      :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
  end
end
