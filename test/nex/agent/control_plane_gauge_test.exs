defmodule Nex.Agent.ControlPlaneGaugeTest do
  use ExUnit.Case, async: true

  require Nex.Agent.Observe.ControlPlane.Gauge

  alias Nex.Agent.Observe.ControlPlane.{Gauge, Query, Store}

  setup do
    workspace = tmp_workspace("gauge")
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "set writes gauge observation and current gauge state", %{workspace: workspace} do
    assert {:ok, observation} =
             Nex.Agent.Observe.ControlPlane.Gauge.set(
               "run.owner.current",
               %{"phase" => "tool"},
               %{"queued" => 1},
               workspace: workspace,
               session_key: "s1"
             )

    assert observation["kind"] == "gauge"
    assert observation["level"] == "info"
    assert observation["context"]["session_key"] == "s1"

    assert %{
             "name" => "run.owner.current",
             "value" => %{"phase" => "tool"},
             "attrs" => %{"queued" => 1}
           } = Gauge.current("run.owner.current", workspace: workspace)

    assert [%{"id" => id}] = Query.query(%{"tag" => "run.owner.current"}, workspace: workspace)
    assert id == observation["id"]
  end

  test "set redacts gauge state before persisting and exposing through summary", %{
    workspace: workspace
  } do
    assert {:ok, _observation} =
             Nex.Agent.Observe.ControlPlane.Gauge.set(
               "run.owner.current",
               %{"api_key" => "sk-secret"},
               %{
                 "message" => "authorization: Bearer abc123 and token=xyz",
                 "workspace" => "/duplicated",
                 "session_key" => "duplicated"
               },
               workspace: workspace
             )

    body = File.read!(Store.gauges_path(workspace: workspace))
    assert body =~ "[REDACTED]"
    refute body =~ "sk-secret"
    refute body =~ "abc123"
    refute body =~ "token=xyz"

    summary = Query.summary(workspace: workspace)
    gauge = summary["gauges"]["run.owner.current"]
    assert gauge["value"]["api_key"] == "[REDACTED]"
    assert gauge["attrs"]["message"] =~ "[REDACTED]"
    refute Map.has_key?(gauge["attrs"], "workspace")
    refute Map.has_key?(gauge["attrs"], "session_key")
  end

  defp tmp_workspace(name) do
    Path.join(
      System.tmp_dir!(),
      "nex-control-plane-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
