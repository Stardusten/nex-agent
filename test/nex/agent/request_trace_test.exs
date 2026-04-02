defmodule Nex.Agent.RequestTraceTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{RequestTrace, Workspace}

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

  test "append_event writes trace lines that can be read back", %{workspace: workspace} do
    opts = [workspace: workspace, request_trace: %{"enabled" => true}]

    assert {:ok, path} =
             RequestTrace.append_event(
               %{
                 "type" => "request_started",
                 "run_id" => "run_trace_store",
                 "prompt" => "inspect request"
               },
               opts
             )

    assert File.exists?(path)

    assert RequestTrace.read_trace("run_trace_store", opts) == [
             %{
               "type" => "request_started",
               "run_id" => "run_trace_store",
               "prompt" => "inspect request",
               "inserted_at" =>
                 hd(RequestTrace.read_trace("run_trace_store", opts))["inserted_at"]
             }
           ]
  end

  test "read_trace skips malformed jsonl rows", %{workspace: workspace} do
    path = Path.join(workspace, "audit/request_traces/run_trace_broken.jsonl")
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      [
        Jason.encode!(%{"type" => "request_started", "run_id" => "run_trace_broken"}),
        "{bad json}",
        Jason.encode!(%{"type" => "request_completed", "run_id" => "run_trace_broken"})
      ]
      |> Enum.join("\n")
    )

    assert RequestTrace.read_trace("run_trace_broken", workspace: workspace) == [
             %{"type" => "request_started", "run_id" => "run_trace_broken"},
             %{"type" => "request_completed", "run_id" => "run_trace_broken"}
           ]
  end
end
