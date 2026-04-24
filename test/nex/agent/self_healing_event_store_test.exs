defmodule Nex.Agent.SelfHealingEventStoreTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.SelfHealing.EventStore

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-self-healing-events-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "append writes normalized JSONL event and recent skips bad lines", %{workspace: workspace} do
    long_error = String.duplicate("x", 1_200)

    assert {:ok, event} =
             EventStore.append(
               %{
                 name: "tool.call.failed",
                 actor: %{tool: "bash"},
                 classifier: %{family: "tool"},
                 evidence: %{error_text: long_error}
               },
               workspace: workspace
             )

    assert event["id"] =~ "evt_"
    assert event["name"] == "tool.call.failed"
    assert event["phase"] == "runtime"
    assert event["severity"] == "error"
    assert event["workspace"] == Path.expand(workspace)
    assert byte_size(event["evidence"]["error_text"]) == 1_000

    File.write!(EventStore.events_path(workspace: workspace), "not json\n", [:append])

    assert [stored] = EventStore.recent(5, workspace: workspace)
    assert stored["id"] == event["id"]
  end
end
