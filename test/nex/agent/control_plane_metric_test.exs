defmodule Nex.Agent.ControlPlaneMetricTest do
  use ExUnit.Case, async: true

  require Nex.Agent.ControlPlane.Metric

  alias Nex.Agent.ControlPlane.Query

  setup do
    workspace = tmp_workspace("metric")
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "count and measure write info metric observations with source", %{workspace: workspace} do
    assert {:ok, count} =
             Nex.Agent.ControlPlane.Metric.count(
               "control_plane.budget.spent",
               3,
               %{"action" => "hint_candidate"},
               workspace: workspace
             )

    assert {:ok, measure} =
             Nex.Agent.ControlPlane.Metric.measure(
               "runner.llm.duration",
               123,
               %{"provider" => "test"},
               workspace: workspace
             )

    assert count["kind"] == "metric"
    assert count["level"] == "info"
    assert count["attrs"]["metric_type"] == "count"
    assert count["attrs"]["value"] == 3
    assert count["source"]["module"] == inspect(__MODULE__)

    assert measure["attrs"]["metric_type"] == "measure"

    assert [%{"id" => id}] =
             Query.query(%{"tag" => "runner.llm.duration"}, workspace: workspace)

    assert id == measure["id"]
  end

  defp tmp_workspace(name) do
    Path.join(
      System.tmp_dir!(),
      "nex-control-plane-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
