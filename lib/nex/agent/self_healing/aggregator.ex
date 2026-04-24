defmodule Nex.Agent.SelfHealing.Aggregator do
  @moduledoc false

  @default_window 20
  @summary_limit 400

  @type summary :: %{
          status: :ok,
          window_size: non_neg_integer(),
          same_name_count: non_neg_integer(),
          same_actor_count: non_neg_integer(),
          consecutive_count: non_neg_integer(),
          summary: String.t(),
          repeated?: boolean()
        }

  @spec summarize(%{event: map(), recent_events: [map()]}) :: summary()
  def summarize(%{event: event, recent_events: recent_events}) do
    event = stringify_keys(event)

    events =
      recent_events
      |> Enum.map(&stringify_keys/1)
      |> ensure_event_in_window(event)
      |> Enum.take(-@default_window)

    event_name = Map.get(event, "name")
    actor_key = actor_key(event)

    same_name_count = Enum.count(events, &(Map.get(&1, "name") == event_name))
    same_actor_count = Enum.count(events, &(actor_key(&1) == actor_key))
    consecutive_count = consecutive_count(events, event_name, actor_key)

    repeated? = same_name_count >= 2 or same_actor_count >= 2 or consecutive_count >= 2

    %{
      status: :ok,
      window_size: length(events),
      same_name_count: same_name_count,
      same_actor_count: same_actor_count,
      consecutive_count: consecutive_count,
      summary: summary_text(event, same_name_count, same_actor_count, consecutive_count),
      repeated?: repeated?
    }
  end

  def summarize(_), do: summarize(%{event: %{}, recent_events: []})

  defp ensure_event_in_window(events, event) do
    event_id = Map.get(event, "id")

    if event_id && Enum.any?(events, &(Map.get(&1, "id") == event_id)) do
      events
    else
      events ++ [event]
    end
  end

  defp consecutive_count(events, event_name, actor_key) do
    events
    |> Enum.reverse()
    |> Enum.take_while(&(Map.get(&1, "name") == event_name and actor_key(&1) == actor_key))
    |> length()
  end

  defp actor_key(event) do
    event
    |> Map.get("actor", %{})
    |> normalize_actor()
  end

  defp normalize_actor(%{"tool" => tool}) when is_binary(tool), do: "tool:" <> tool

  defp normalize_actor(%{"component" => component}) when is_binary(component),
    do: "component:" <> component

  defp normalize_actor(%{"module" => module}) when is_binary(module), do: "module:" <> module
  defp normalize_actor(actor) when is_map(actor), do: inspect(Enum.sort(actor))
  defp normalize_actor(_), do: "unknown"

  defp summary_text(event, same_name_count, same_actor_count, consecutive_count) do
    name = Map.get(event, "name", "unknown")
    actor = Map.get(event, "actor", %{}) |> normalize_actor()
    severity = Map.get(event, "severity", "error")

    [
      "event=#{name}",
      "actor=#{actor}",
      "severity=#{severity}",
      "same_name=#{same_name_count}",
      "same_actor=#{same_actor_count}",
      "consecutive=#{consecutive_count}"
    ]
    |> Enum.join(" ")
    |> String.slice(0, @summary_limit)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_keys(_), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
