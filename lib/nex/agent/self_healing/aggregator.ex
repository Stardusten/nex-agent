defmodule Nex.Agent.SelfHealing.Aggregator do
  @moduledoc false

  @default_window 20
  @summary_limit 400

  @type summary :: %{
          status: :ok,
          window_size: non_neg_integer(),
          same_tag_count: non_neg_integer(),
          same_actor_count: non_neg_integer(),
          consecutive_count: non_neg_integer(),
          summary: String.t(),
          repeated?: boolean()
        }

  @spec summarize(%{event: map(), recent_events: [map()]}) :: summary()
  def summarize(%{event: event, recent_events: recent_events}) do
    event = normalize_observation(event)

    events =
      recent_events
      |> Enum.map(&normalize_observation/1)
      |> ensure_event_in_window(event)
      |> Enum.take(-@default_window)

    tag = Map.get(event, "tag")
    actor = actor_key(event)

    same_tag_count = Enum.count(events, &(Map.get(&1, "tag") == tag))
    same_actor_count = Enum.count(events, &(actor_key(&1) == actor))
    consecutive_count = consecutive_count(events, tag, actor)

    repeated? = same_tag_count >= 2 or same_actor_count >= 2 or consecutive_count >= 2

    %{
      status: :ok,
      window_size: length(events),
      same_tag_count: same_tag_count,
      same_actor_count: same_actor_count,
      consecutive_count: consecutive_count,
      summary: summary_text(event, same_tag_count, same_actor_count, consecutive_count),
      repeated?: repeated?
    }
  end

  def summarize(_), do: summarize(%{event: %{}, recent_events: []})

  @spec patterns([map()]) :: [map()]
  def patterns(observations) when is_list(observations) do
    observations
    |> Enum.map(&normalize_observation/1)
    |> Enum.reject(&(Map.get(&1, "tag") in [nil, ""]))
    |> Enum.group_by(&Map.get(&1, "tag"))
    |> Enum.map(fn {tag, grouped} -> build_pattern(tag, grouped) end)
    |> Enum.reject(&(Map.get(&1, "count", 0) < 2))
    |> Enum.sort_by(fn pattern -> {-pattern["count"], severity_rank(pattern["severity"])} end)
  end

  def patterns(_), do: []

  defp ensure_event_in_window(events, event) do
    event_id = Map.get(event, "id")

    if event_id && Enum.any?(events, &(Map.get(&1, "id") == event_id)) do
      events
    else
      events ++ [event]
    end
  end

  defp consecutive_count(events, tag, actor) do
    events
    |> Enum.reverse()
    |> Enum.take_while(&(Map.get(&1, "tag") == tag and actor_key(&1) == actor))
    |> length()
  end

  defp build_pattern(tag, grouped) do
    sorted =
      Enum.sort_by(grouped, fn observation ->
        Map.get(observation, "timestamp", "")
      end)

    severities = Enum.map(sorted, &Map.get(&1, "level", "warning"))

    %{
      "tag" => tag,
      "count" => length(sorted),
      "severity" => highest_severity(severities),
      "actors" =>
        sorted
        |> Enum.map(&actor_key/1)
        |> Enum.reject(&(&1 == "unknown"))
        |> Enum.uniq(),
      "sample_ids" =>
        sorted
        |> Enum.take(-5)
        |> Enum.map(&Map.get(&1, "id"))
        |> Enum.reject(&is_nil/1),
      "first_seen" => sorted |> List.first() |> Map.get("timestamp"),
      "last_seen" => sorted |> List.last() |> Map.get("timestamp")
    }
  end

  defp highest_severity(levels) do
    cond do
      "critical" in levels -> "critical"
      "error" in levels -> "error"
      "warning" in levels -> "warning"
      true -> "info"
    end
  end

  defp severity_rank("critical"), do: 0
  defp severity_rank("error"), do: 1
  defp severity_rank("warning"), do: 2
  defp severity_rank(_), do: 3

  defp summary_text(event, same_tag_count, same_actor_count, consecutive_count) do
    tag = Map.get(event, "tag", "unknown")
    actor = actor_key(event)
    severity = Map.get(event, "level", "error")

    [
      "tag=#{tag}",
      "actor=#{actor}",
      "severity=#{severity}",
      "same_tag=#{same_tag_count}",
      "same_actor=#{same_actor_count}",
      "consecutive=#{consecutive_count}"
    ]
    |> Enum.join(" ")
    |> String.slice(0, @summary_limit)
  end

  defp actor_key(observation) do
    attrs = Map.get(observation, "attrs_summary", %{})

    cond do
      is_binary(attrs["tool_name"]) -> "tool:" <> attrs["tool_name"]
      is_binary(attrs["actor"]) -> attrs["actor"]
      is_binary(attrs["reason_type"]) -> "reason:" <> attrs["reason_type"]
      is_binary(get_in(observation, ["context", "channel"])) ->
        "channel:" <> get_in(observation, ["context", "channel"])

      true ->
        "unknown"
    end
  end

  defp normalize_observation(observation) when is_map(observation) do
    observation =
      observation
      |> Map.new(fn {key, value} -> {to_string(key), normalize_value(value)} end)

    cond do
      Map.has_key?(observation, "tag") ->
        %{
          "id" => Map.get(observation, "id"),
          "timestamp" => Map.get(observation, "timestamp"),
          "tag" => Map.get(observation, "tag"),
          "level" => Map.get(observation, "level", "warning"),
          "context" => Map.get(observation, "context", %{}),
          "attrs_summary" =>
            Map.get(observation, "attrs_summary") ||
              observation["attrs"] ||
              %{}
        }

      true ->
        %{
          "id" => Map.get(observation, "id"),
          "timestamp" => Map.get(observation, "timestamp"),
          "tag" => Map.get(observation, "name"),
          "level" => Map.get(observation, "severity", "warning"),
          "context" => Map.get(observation, "context", %{}),
          "attrs_summary" =>
            %{}
            |> maybe_put("tool_name", get_in(observation, ["actor", "tool"]))
            |> maybe_put("actor", normalize_actor(Map.get(observation, "actor")))
        }
    end
  end

  defp normalize_observation(_), do: %{}

  defp normalize_actor(%{"tool" => tool}) when is_binary(tool), do: "tool:" <> tool
  defp normalize_actor(%{"component" => component}) when is_binary(component), do: component
  defp normalize_actor(%{"module" => module}) when is_binary(module), do: module
  defp normalize_actor(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_value(nested)} end)
  end

  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value
end
