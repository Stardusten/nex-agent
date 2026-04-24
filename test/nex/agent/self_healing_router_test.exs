defmodule Nex.Agent.SelfHealingRouterTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.SelfHealing.{EnergyLedger, EventStore, Router}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-self-healing-router-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "sleep mode records only", %{workspace: workspace} do
    write_energy(workspace, 0)

    decision = Router.decide(event("tool.call.failed"), repeated_summary(), workspace: workspace)

    assert decision.action == :record_only
    assert decision.energy_mode == :sleep
    assert decision.energy_spent == 0
  end

  test "low repeated failures produce hint candidate when energy is sufficient", %{
    workspace: workspace
  } do
    write_energy(workspace, 10)

    decision = Router.decide(event("tool.call.failed"), repeated_summary(), workspace: workspace)

    assert decision.action == :hint_candidate
    assert decision.energy_spent == 3
    assert EnergyLedger.current(workspace: workspace)["current"] == 7
  end

  test "normal high severity failures produce reflect candidate", %{workspace: workspace} do
    write_energy(workspace, 60)

    decision =
      Router.decide(
        Map.put(event("llm.call.failed"), "severity", "critical"),
        Map.put(repeated_summary(), :repeated?, false),
        workspace: workspace
      )

    assert decision.action == :reflect_candidate
    assert decision.energy_spent == 9
    assert EnergyLedger.current(workspace: workspace)["current"] == 51
  end

  test "normal one-off error records only", %{workspace: workspace} do
    write_energy(workspace, 60)

    decision =
      Router.decide(
        event("llm.call.failed"),
        Map.put(repeated_summary(), :repeated?, false),
        workspace: workspace
      )

    assert decision.action == :record_only
    assert decision.energy_spent == 0
    assert EnergyLedger.current(workspace: workspace)["current"] == 60
  end

  test "normal repeated failures produce reflect candidate", %{workspace: workspace} do
    write_energy(workspace, 60)

    decision = Router.decide(event("tool.call.failed"), repeated_summary(), workspace: workspace)

    assert decision.action == :reflect_candidate
    assert decision.energy_spent == 9
    assert EnergyLedger.current(workspace: workspace)["current"] == 51
  end

  test "insufficient energy falls back to record_only", %{workspace: workspace} do
    write_energy(workspace, 2)

    decision = Router.decide(event("tool.call.failed"), repeated_summary(), workspace: workspace)

    assert decision.action == :record_only
    assert decision.energy_spent == 0
    assert EnergyLedger.current(workspace: workspace)["current"] == 2
  end

  test "record_event stores event with bounded decision", %{workspace: workspace} do
    write_energy(workspace, 60)
    {:ok, _previous} = EventStore.append(event("self_update.deploy.failed"), workspace: workspace)

    assert {:ok, stored} =
             Router.record_event(
               event("self_update.deploy.failed"),
               workspace: workspace
             )

    assert stored["decision"]["action"] == "reflect_candidate"
    assert stored["energy_cost"] == 9
    assert [stored_event] = EventStore.recent(1, workspace: workspace)
    assert stored_event["id"] == stored["id"]
  end

  defp event(name) do
    %{
      "name" => name,
      "severity" => "error",
      "actor" => %{"component" => "runner"},
      "classifier" => %{},
      "evidence" => %{"error_text" => "failed"}
    }
  end

  defp repeated_summary do
    %{
      status: :ok,
      window_size: 2,
      same_name_count: 2,
      same_actor_count: 2,
      consecutive_count: 2,
      summary: "event=tool.call.failed actor=tool:bash same_name=2",
      repeated?: true
    }
  end

  defp write_energy(workspace, current) do
    path = EventStore.energy_path(workspace: workspace)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "capacity" => 100,
        "current" => current,
        "mode" => Atom.to_string(EnergyLedger.mode(%{"current" => current})),
        "refill_rate" => 10,
        "last_refilled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "spent_today" => 0
      })
    )
  end
end
