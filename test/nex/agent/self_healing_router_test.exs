defmodule Nex.Agent.SelfHealingRouterTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.ControlPlane.{Budget, Log, Query}
  alias Nex.Agent.SelfHealing.Router
  require Log

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

    decision =
      Router.decide(event("runner.tool.call.failed"), repeated_summary(), workspace: workspace)

    assert decision.action == :record_only
    assert decision.energy_mode == :sleep
    assert decision.energy_spent == 0
  end

  test "low repeated failures produce hint candidate when energy is sufficient", %{
    workspace: workspace
  } do
    write_energy(workspace, 10)

    decision =
      Router.decide(event("runner.tool.call.failed"), repeated_summary(), workspace: workspace)

    assert decision.action == :hint_candidate
    assert decision.energy_spent == 3
    assert Budget.current(workspace: workspace)["current"] == 7
  end

  test "normal high severity failures produce reflect candidate", %{workspace: workspace} do
    write_energy(workspace, 60)

    decision =
      Router.decide(
        Map.put(event("runner.llm.call.failed"), "severity", "critical"),
        Map.put(repeated_summary(), :repeated?, false),
        workspace: workspace
      )

    assert decision.action == :reflect_candidate
    assert decision.energy_spent == 9
    assert Budget.current(workspace: workspace)["current"] == 51
  end

  test "normal one-off error records only", %{workspace: workspace} do
    write_energy(workspace, 60)

    decision =
      Router.decide(
        event("runner.llm.call.failed"),
        Map.put(repeated_summary(), :repeated?, false),
        workspace: workspace
      )

    assert decision.action == :record_only
    assert decision.energy_spent == 0
    assert Budget.current(workspace: workspace)["current"] == 60
  end

  test "normal repeated failures produce reflect candidate", %{workspace: workspace} do
    write_energy(workspace, 60)

    decision =
      Router.decide(event("runner.tool.call.failed"), repeated_summary(), workspace: workspace)

    assert decision.action == :reflect_candidate
    assert decision.energy_spent == 9
    assert Budget.current(workspace: workspace)["current"] == 51
  end

  test "insufficient energy falls back to record_only", %{workspace: workspace} do
    write_energy(workspace, 2)

    decision =
      Router.decide(event("runner.tool.call.failed"), repeated_summary(), workspace: workspace)

    assert decision.action == :record_only
    assert decision.energy_spent == 0
    assert Budget.current(workspace: workspace)["current"] == 2
  end

  test "record_event stores event with bounded decision", %{workspace: workspace} do
    write_energy(workspace, 60)

    assert {:ok, _previous} =
             Log.error("self_update.deploy.failed", event_attrs(), workspace: workspace)

    assert {:ok, stored} =
             Router.record_event(
               event("self_update.deploy.failed"),
               workspace: workspace
             )

    assert stored["attrs_summary"]["decision"]["action"] == "reflect_candidate"
    assert stored["attrs_summary"]["energy_cost"] == 9
    assert [stored_event] = query_events(workspace, tag: "self_update.deploy.failed", limit: 1)
    assert stored_event["tag"] == "self_update.deploy.failed"
    assert stored_event["attrs"]["decision"]["action"] == "reflect_candidate"
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

  defp event_attrs do
    Map.drop(event("self_update.deploy.failed"), ["name", "severity"])
  end

  defp repeated_summary do
    %{
      status: :ok,
      window_size: 2,
      same_tag_count: 2,
      same_actor_count: 2,
      consecutive_count: 2,
      summary: "tag=runner.tool.call.failed actor=tool:bash same_tag=2",
      repeated?: true
    }
  end

  defp write_energy(workspace, current) do
    path = Path.join([workspace, "control_plane", "state", "budget.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "capacity" => 100,
        "current" => current,
        "mode" => Atom.to_string(mode_for_current(current)),
        "refill_rate" => 10,
        "last_refilled_at" =>
          DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.to_iso8601(),
        "spent_today" => 0
      })
    )
  end

  defp mode_for_current(0), do: :sleep
  defp mode_for_current(current) when current < 20, do: :low
  defp mode_for_current(current) when current < 70, do: :normal
  defp mode_for_current(_current), do: :deep

  defp query_events(workspace, filters) do
    filters
    |> Map.new()
    |> Query.query(workspace: workspace)
    |> case do
      {:ok, %{"observations" => observations}} -> observations
      {:ok, %{observations: observations}} -> observations
      {:ok, observations} -> observations
      observations when is_list(observations) -> observations
    end
  end
end
