defmodule Nex.Agent.ControlPlaneLogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Nex.Agent.ControlPlane.Log

  alias Nex.Agent.ControlPlane.Query

  setup do
    workspace = tmp_workspace("log")
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "log macro captures source and writes an observation", %{workspace: workspace} do
    assert {:ok, observation} =
             Nex.Agent.ControlPlane.Log.error(
               "runner.llm.call.failed",
               %{"provider" => "test"},
               workspace: workspace,
               run_id: "run-1"
             )

    assert observation["kind"] == "log"
    assert observation["level"] == "error"
    assert observation["source"]["module"] == inspect(__MODULE__)

    assert observation["source"]["function"] ==
             "test log macro captures source and writes an observation/1"

    assert observation["source"]["line"] > 0
    assert observation["context"]["run_id"] == "run-1"

    assert [stored] = Query.query(%{"tag" => "runner.llm.call.failed"}, workspace: workspace)
    assert stored["id"] == observation["id"]
  end

  test "log projection uses redacted attrs", %{workspace: workspace} do
    log =
      capture_log(fn ->
        assert {:ok, _observation} =
                 Nex.Agent.ControlPlane.Log.error(
                   "runner.llm.call.failed",
                   %{
                     "api_key" => "sk-secret",
                     "message" => "authorization: Bearer abc123 and token=xyz"
                   },
                   workspace: workspace
                 )
      end)

    assert log =~ "[REDACTED]"
    refute log =~ "sk-secret"
    refute log =~ "abc123"
    refute log =~ "token=xyz"
  end

  defp tmp_workspace(name) do
    Path.join(
      System.tmp_dir!(),
      "nex-control-plane-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
