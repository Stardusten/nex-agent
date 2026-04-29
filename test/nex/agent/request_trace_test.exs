defmodule Nex.Agent.Observe.Compat.RequestTraceTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Observe.Compat.RequestTrace, Runtime.Workspace}
  alias Nex.Agent.Observe.ControlPlane.Log
  require Log

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-request-trace-#{System.unique_integer([:positive])}"
      )

    Workspace.ensure!(workspace: workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "append_event records control-plane observations that can be read back", %{
    workspace: workspace
  } do
    opts = [workspace: workspace, request_trace: %{"enabled" => true}]

    assert {:ok, "run_trace_store"} =
             RequestTrace.append_event(
               %{
                 "type" => "request_started",
                 "run_id" => "run_trace_store",
                 "prompt" => "inspect request"
               },
               opts
             )

    assert ["run_trace_store"] = RequestTrace.list_paths(opts)

    assert RequestTrace.read_trace("run_trace_store", opts) == [
             %{
               "type" => "request_started",
               "run_id" => "run_trace_store",
               "prompt_summary" => "inspect request",
               "inserted_at" =>
                 hd(RequestTrace.read_trace("run_trace_store", opts))["inserted_at"]
             }
           ]
  end

  test "read_trace ignores legacy request trace jsonl files", %{workspace: workspace} do
    legacy_path = Path.join(workspace, "audit/request_traces/run_trace_legacy.jsonl")
    File.mkdir_p!(Path.dirname(legacy_path))
    File.write!(legacy_path, Jason.encode!(%{"type" => "request_started"}) <> "\n")

    assert RequestTrace.read_trace("run_trace_legacy", workspace: workspace) == []
  end

  test "read_trace includes non-request-trace run observations", %{workspace: workspace} do
    opts = [workspace: workspace, run_id: "run_observed"]

    assert {:ok, _} =
             Log.info(
               "runner.tool.call.finished",
               %{"tool_name" => "read", "duration_ms" => 12, "result_status" => "ok"},
               opts
             )

    assert ["run_observed"] = RequestTrace.list_paths(workspace: workspace)

    assert [
             %{
               "type" => "runner.tool.call.finished",
               "tag" => "runner.tool.call.finished",
               "run_id" => "run_observed",
               "duration_ms" => 12,
               "attrs_summary" => %{"tool_name" => "read", "result_status" => "ok"}
             }
           ] = RequestTrace.read_trace("run_observed", workspace: workspace)
  end
end
