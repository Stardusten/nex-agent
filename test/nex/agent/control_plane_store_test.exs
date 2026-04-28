defmodule Nex.Agent.ControlPlaneStoreTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.ControlPlane.{Query, Store}

  setup do
    workspace = tmp_workspace("store")
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "append writes normalized JSONL observations and query skips bad lines", %{
    workspace: workspace
  } do
    assert {:ok, observation} =
             Store.append(
               %{
                 "kind" => "log",
                 "level" => "error",
                 "tag" => "runner.tool.call.failed",
                 "source" => %{
                   "module" => "Nex.Agent.Runner",
                   "function" => "run/2",
                   "file" => "lib/nex/agent/runner.ex",
                   "line" => 42
                 },
                 "context" => %{"workspace" => "/ignored", "run_id" => "run-1"},
                 "attrs" => %{"tool_name" => "bash"}
               },
               workspace: workspace
             )

    assert observation["id"] =~ "obs_"
    assert observation["tag"] == "runner.tool.call.failed"
    assert observation["context"]["workspace"] == Path.expand(workspace)
    refute Map.has_key?(observation, "workspace")
    refute Map.has_key?(observation["attrs"], "workspace")

    File.write!(
      Store.observations_path(observation["timestamp"], workspace: workspace),
      "bad\n",
      [
        :append
      ]
    )

    assert [stored] = Store.query(%{"run_id" => "run-1"}, workspace: workspace)
    assert stored["id"] == observation["id"]
  end

  test "redacts sensitive keys and text before writing store contents", %{workspace: workspace} do
    assert {:ok, observation} =
             Store.append(
               %{
                 "tag" => "runner.llm.call.failed",
                 "source" => %{"module" => "M", "file" => "f", "line" => 1},
                 "attrs" => %{
                   "api_key" => "sk-secret",
                   "message" => "authorization: Bearer abc123 and token=xyz"
                 }
               },
               workspace: workspace
             )

    body = File.read!(Store.observations_path(observation["timestamp"], workspace: workspace))
    assert body =~ "[REDACTED]"
    refute body =~ "sk-secret"
    refute body =~ "abc123"
    refute body =~ "token=xyz"
  end

  test "drops context identity keys from attrs", %{workspace: workspace} do
    assert {:ok, observation} =
             Store.append(
               %{
                 "tag" => "runner.tool.call.failed",
                 "source" => %{"module" => "M", "file" => "f", "line" => 1},
                 "context" => %{"run_id" => "run-1"},
                 "attrs" => %{
                   "workspace" => "/wrong",
                   "run_id" => "run-wrong",
                   "session_key" => "session-wrong",
                   "reason" => "failed"
                 }
               },
               workspace: workspace,
               session_key: "session-1"
             )

    assert observation["context"]["workspace"] == Path.expand(workspace)
    assert observation["context"]["run_id"] == "run-1"
    assert observation["context"]["session_key"] == "session-1"
    assert observation["attrs"] == %{"reason" => "failed"}
  end

  test "query filters by tag, level, session key, since and query text", %{workspace: workspace} do
    old_timestamp = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    since = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.to_iso8601()

    {:ok, _old} =
      Store.append(
        %{
          "timestamp" => old_timestamp,
          "level" => "error",
          "tag" => "runner.tool.call.failed",
          "source" => %{"module" => "M", "file" => "f", "line" => 1},
          "context" => %{"session_key" => "s1"},
          "attrs" => %{"reason" => "old"}
        },
        workspace: workspace
      )

    {:ok, new} =
      Store.append(
        %{
          "level" => "warning",
          "tag" => "self_update.deploy.failed",
          "source" => %{"module" => "M", "file" => "f", "line" => 1},
          "context" => %{"session_key" => "s2"},
          "attrs" => %{"reason" => "deploy exploded"}
        },
        workspace: workspace
      )

    assert [stored] =
             Store.query(
               %{
                 "level" => "warning",
                 "session_key" => "s2",
                 "query" => "exploded",
                 "since" => since
               },
               workspace: workspace
             )

    assert stored["id"] == new["id"]
    assert [] = Store.query(%{"tag" => "missing"}, workspace: workspace)
  end

  test "query limit returns latest observations in chronological order", %{workspace: workspace} do
    Enum.each(
      [
        {"oldest", "2026-04-24T10:00:00Z"},
        {"middle", "2026-04-25T10:00:00Z"},
        {"newer", "2026-04-26T10:00:00Z"},
        {"latest", "2026-04-26T11:00:00Z"}
      ],
      fn {id, timestamp} ->
        assert {:ok, _} =
                 Store.append(
                   %{
                     "id" => id,
                     "timestamp" => timestamp,
                     "tag" => "store.query.test",
                     "source" => %{"module" => "M", "file" => "f", "line" => 1},
                     "attrs" => %{"id" => id}
                   },
                   workspace: workspace
                 )
      end
    )

    assert ["newer", "latest"] =
             Store.query(%{"tag" => "store.query.test", "limit" => 2}, workspace: workspace)
             |> Enum.map(& &1["id"])
  end

  test "query since keeps boundary semantics across observation files", %{workspace: workspace} do
    Enum.each(
      [
        {"before", "2026-04-24T23:59:59Z"},
        {"boundary", "2026-04-25T00:00:00Z"},
        {"after", "2026-04-26T00:00:00Z"}
      ],
      fn {id, timestamp} ->
        assert {:ok, _} =
                 Store.append(
                   %{
                     "id" => id,
                     "timestamp" => timestamp,
                     "tag" => "store.query.since",
                     "source" => %{"module" => "M", "file" => "f", "line" => 1},
                     "attrs" => %{"id" => id}
                   },
                   workspace: workspace
                 )
      end
    )

    assert ["boundary", "after"] =
             Store.query(
               %{
                 "tag" => "store.query.since",
                 "since" => "2026-04-25T00:00:00Z",
                 "limit" => 10
               },
               workspace: workspace
             )
             |> Enum.map(& &1["id"])
  end

  test "query derives run trace summaries and details from observations", %{workspace: workspace} do
    {:ok, _} =
      Store.append(
        %{
          "tag" => "runner.run.started",
          "source" => %{"module" => "M", "file" => "f", "line" => 1},
          "context" => %{"run_id" => "run-trace", "channel" => "feishu", "chat_id" => "chat-1"},
          "attrs" => %{}
        },
        workspace: workspace
      )

    {:ok, _} =
      Store.append(
        %{
          "tag" => "runner.llm.call.finished",
          "source" => %{"module" => "M", "file" => "f", "line" => 1},
          "context" => %{"run_id" => "run-trace"},
          "attrs" => %{"iteration" => 1, "finish_reason" => "stop", "duration_ms" => 12}
        },
        workspace: workspace
      )

    {:ok, _} =
      Store.append(
        %{
          "tag" => "runner.tool.call.finished",
          "source" => %{"module" => "M", "file" => "f", "line" => 1},
          "context" => %{"run_id" => "run-trace", "tool_call_id" => "tool-1"},
          "attrs" => %{
            "tool_name" => "skill_get",
            "args_summary" => "%{\"task\" => \"restore service\"}",
            "result_status" => "ok",
            "iteration" => 1
          }
        },
        workspace: workspace
      )

    {:ok, _} =
      Store.append(
        %{
          "tag" => "runner.run.finished",
          "source" => %{"module" => "M", "file" => "f", "line" => 1},
          "context" => %{"run_id" => "run-trace"},
          "attrs" => %{"result_status" => "ok"}
        },
        workspace: workspace
      )

    [summary] = Query.recent_run_trace_summaries(workspace: workspace)
    detail = Query.run_trace_detail("run-trace", workspace: workspace)

    assert summary.run_id == "run-trace"
    assert summary.status == "completed"
    assert summary.tool_count == 1
    assert summary.llm_rounds == 1
    assert summary.used_tools == ["skill_get"]

    assert detail.run_id == "run-trace"
    assert detail.channel == "feishu"
    assert detail.chat_id == "chat-1"
    assert detail.tool_count == 1
    assert detail.llm_rounds == 1
    assert detail.used_tools == ["skill_get"]
    assert [activity] = detail.tool_activity
    assert activity.kind == :tool
    assert activity.tool_call_id == "tool-1"
    assert [turn] = detail.llm_turns
    assert turn.finish_reason == "stop"
    assert turn.duration_ms == 12
  end

  defp tmp_workspace(name) do
    Path.join(
      System.tmp_dir!(),
      "nex-control-plane-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
