defmodule Nex.Agent.ObserveToolTest do
  use ExUnit.Case, async: true

  require Nex.Agent.ControlPlane.Gauge
  require Nex.Agent.ControlPlane.Log
  require Nex.Agent.ControlPlane.Metric

  alias Nex.Agent.ControlPlane.Budget
  alias Nex.Agent.Tool.Observe

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-observe-tool-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "summary returns recent failures, gauges, and budget", %{workspace: workspace} do
    {:ok, _log} =
      Nex.Agent.ControlPlane.Log.error(
        "runner.tool.call.failed",
        %{"tool_name" => "bash"},
        workspace: workspace,
        run_id: "run-1"
      )

    {:ok, _gauge} =
      Nex.Agent.ControlPlane.Gauge.set(
        "run.owner.current",
        %{"phase" => "tool"},
        %{},
        workspace: workspace
      )

    Budget.current(workspace: workspace)

    assert {:ok, result} = Observe.execute(%{"action" => "summary"}, %{"workspace" => workspace})
    assert [%{"tag" => "runner.tool.call.failed"}] = result["recent_warnings_or_errors"]
    assert result["gauges"]["run.owner.current"]["value"] == %{"phase" => "tool"}
    assert result["budget"]["mode"] == "normal"
  end

  test "query, tail, metrics, and incident read only ControlPlane data", %{workspace: workspace} do
    {:ok, log} =
      Nex.Agent.ControlPlane.Log.error(
        "self_update.deploy.failed",
        %{"reason" => "compile failed"},
        workspace: workspace,
        session_key: "s1"
      )

    {:ok, metric} =
      Nex.Agent.ControlPlane.Metric.count(
        "control_plane.budget.spent",
        2,
        %{"action" => "hint_candidate"},
        workspace: workspace
      )

    assert {:ok, %{"observations" => [%{"id" => id}]}} =
             Observe.execute(
               %{"action" => "query", "tag" => "self_update.deploy.failed"},
               %{"workspace" => workspace}
             )

    assert id == log["id"]

    assert {:ok, %{"observations" => tail}} =
             Observe.execute(%{"action" => "tail", "limit" => 1}, %{"workspace" => workspace})

    assert length(tail) == 1

    assert {:ok, %{"observations" => metrics}} =
             Observe.execute(%{"action" => "metrics"}, %{"workspace" => workspace})

    assert Enum.any?(metrics, &(&1["id"] == metric["id"]))

    assert {:ok, %{"errors" => [%{"id" => incident_id}]}} =
             Observe.execute(
               %{"action" => "incident", "session_key" => "s1"},
               %{"workspace" => workspace}
             )

    assert incident_id == log["id"]
  end

  test "rejects path arguments", %{workspace: workspace} do
    assert {:error, "observe does not accept file paths"} =
             Observe.execute(%{"action" => "tail", "path" => "/tmp/nope"}, %{
               "workspace" => workspace
             })
  end
end
