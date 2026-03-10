defmodule Nex.Agent.SubAgent.EvolutionTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Memory
  alias Nex.Agent.SubAgent.Evolution

  defmodule SlowAgent do
    def version, do: "v1.2.3"
  end

  setup_all do
    backup_dir =
      Path.join(System.tmp_dir!(), "nex_agent_evolution_backup_#{System.unique_integer([:positive])}")

    original_exists = File.exists?(memory_dir())

    if original_exists do
      {:ok, _files} = File.cp_r(memory_dir(), backup_dir)
    end

    on_exit(fn ->
      File.rm_rf(memory_dir())

      if original_exists do
        {:ok, _files} = File.cp_r(backup_dir, memory_dir())
      else
        File.mkdir_p!(memory_dir())
      end

      File.rm_rf(backup_dir)
    end)

    :ok
  end

  setup do
    File.rm_rf(memory_dir())
    File.mkdir_p!(memory_dir())
    File.write!(history_path(), "")
    :ok
  end

  test "self_reflect reads recent performance metrics from HISTORY.md" do
    Evolution.record_performance(SlowAgent, %{
      task_type: "review",
      success: false,
      duration_ms: 45_000,
      tool_calls: ["read", "bash"],
      user_feedback: "too slow"
    })

    Evolution.record_performance(SlowAgent, %{
      task_type: "review",
      success: false,
      duration_ms: 41_000,
      tool_calls: ["read"],
      user_feedback: nil
    })

    assert {:ok, suggestion} = Evolution.self_reflect(SlowAgent, window: "7d", min_tasks: 2)
    assert suggestion.module == SlowAgent
    assert suggestion.current_version == "v1.2.3"
    assert suggestion.suggested_version == "v1.2.4"
    assert suggestion.risk_level in [:medium, :high]
    assert suggestion.reason =~ "Success rate"
  end

  test "self_reflect ignores metrics from other modules" do
    Evolution.record_performance(SlowAgent, %{
      task_type: "review",
      success: false,
      duration_ms: 45_000
    })

    Evolution.record_performance(__MODULE__, %{
      task_type: "review",
      success: false,
      duration_ms: 45_000
    })

    assert {:ok, nil} = Evolution.self_reflect(SlowAgent, window: "7d", min_tasks: 2)
  end

  defp memory_dir do
    Path.join(Memory.workspace_path(), "memory")
  end

  defp history_path do
    Path.join(memory_dir(), "HISTORY.md")
  end
end
