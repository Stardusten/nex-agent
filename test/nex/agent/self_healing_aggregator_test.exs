defmodule Nex.Agent.SelfHealingAggregatorTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Self.Healing.Aggregator

  test "summarize detects repeated same event and actor" do
    old_event = event("evt_1", "tool.call.failed", %{"tool" => "bash"})
    current = event("evt_2", "tool.call.failed", %{"tool" => "bash"})

    assert %{
             status: :ok,
             window_size: 2,
             same_tag_count: 2,
             same_actor_count: 2,
             consecutive_count: 2,
             repeated?: true,
             summary: summary
           } = Aggregator.summarize(%{event: current, recent_events: [old_event]})

    assert summary =~ "tag=tool.call.failed"
    assert summary =~ "actor=tool:bash"
  end

  test "summarize keeps non-repeated events cheap and structured" do
    current = event("evt_2", "llm.call.failed", %{"component" => "runner"})

    assert %{
             repeated?: false,
             same_tag_count: 1,
             same_actor_count: 1,
             consecutive_count: 1
           } = Aggregator.summarize(%{event: current, recent_events: []})
  end

  defp event(id, name, actor) do
    %{
      "id" => id,
      "name" => name,
      "severity" => "error",
      "actor" => actor
    }
  end
end
