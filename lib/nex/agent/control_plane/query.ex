defmodule Nex.Agent.ControlPlane.Query do
  @moduledoc false

  alias Nex.Agent.ControlPlane.Redactor
  alias Nex.Agent.ControlPlane.{Budget, Gauge, Store}

  @summary_limit 1000

  @spec query(map() | keyword(), keyword()) :: [Store.observation()]
  def query(filters \\ %{}, opts \\ []) do
    Store.query(filters, opts)
  end

  @spec tail(pos_integer(), keyword()) :: [Store.observation()]
  def tail(limit \\ 20, opts \\ []) do
    Store.query(%{"limit" => limit}, opts)
  end

  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    recent =
      Store.query(%{"limit" => Keyword.get(opts, :limit, 20)}, opts)

    %{
      "recent" => recent,
      "recent_warnings_or_errors" =>
        Enum.filter(recent, &(&1["level"] in ["warning", "error", "critical"])),
      "gauges" => Gauge.all(opts),
      "budget" => Budget.current(opts)
    }
  end

  @spec metrics(map() | keyword(), keyword()) :: map()
  def metrics(filters \\ %{}, opts \\ []) do
    observations =
      filters
      |> Map.new()
      |> Map.put("limit", Map.get(Map.new(filters), "limit", 50))
      |> Store.query(opts)
      |> Enum.filter(&(&1["kind"] in ["metric", "gauge"]))

    %{"observations" => observations, "gauges" => Gauge.all(opts)}
  end

  @spec incident(map() | keyword(), keyword()) :: map()
  def incident(filters \\ %{}, opts \\ []) do
    filters = Map.new(filters)

    observations =
      filters
      |> Map.put_new("limit", 50)
      |> Store.query(opts)

    %{
      "filters" => Store.stringify_keys(filters),
      "observations" => observations,
      "errors" => Enum.filter(observations, &(&1["level"] in ["error", "critical"])),
      "metrics" => Enum.filter(observations, &(&1["kind"] in ["metric", "gauge"]))
    }
  end

  @spec observation_summary(map()) :: map()
  def observation_summary(observation) when is_map(observation) do
    %{
      "id" => Map.get(observation, "id"),
      "timestamp" => Map.get(observation, "timestamp"),
      "level" => Map.get(observation, "level"),
      "tag" => Map.get(observation, "tag"),
      "context" => Map.get(observation, "context", %{}),
      "attrs_summary" =>
        observation
        |> Map.get("attrs", %{})
        |> summarize_attrs()
    }
  end

  @spec recent_events(keyword()) :: [map()]
  def recent_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    %{}
    |> maybe_put_filter("tag_prefix", Keyword.get(opts, :tag_prefix))
    |> maybe_put_filter("level", Keyword.get(opts, :level))
    |> maybe_put_filter("run_id", Keyword.get(opts, :run_id))
    |> maybe_put_filter("session_key", Keyword.get(opts, :session_key))
    |> Map.put("limit", limit)
    |> query(opts)
    |> Enum.map(&observation_summary/1)
    |> Enum.reverse()
  end

  @spec run_trace(String.t(), keyword()) :: map()
  def run_trace(run_id, opts \\ []) when is_binary(run_id) do
    observations =
      %{"run_id" => run_id, "limit" => Keyword.get(opts, :limit, 200)}
      |> query(opts)

    summaries = Enum.map(observations, &observation_summary/1)

    %{
      "run_id" => run_id,
      "observations" => summaries,
      "started_at" => started_at(observations),
      "finished_at" => finished_at(observations),
      "levels" => count_by(observations, "level"),
      "tags" => count_by(observations, "tag")
    }
  end

  @spec run_trace_summary(map()) :: map() | nil
  def run_trace_summary(%{"run_id" => run_id, "observations" => observations} = trace) do
    started_at = trace["started_at"] || (List.first(observations) || %{})["timestamp"]
    finished_at = trace["finished_at"]
    tags = trace["tags"] || %{}
    status = trace_status(trace)
    tool_tags = Map.take(tags, ["runner.tool.call.finished", "runner.tool.call.failed"])

    if observations == [] do
      nil
    else
      %{
        run_id: run_id,
        prompt: nil,
        inserted_at: started_at,
        status: status,
        result: nil,
        tool_count: Enum.sum(Map.values(tool_tags)),
        llm_rounds: Map.get(tags, "runner.llm.call.finished", 0),
        selected_packages: [],
        used_tools: trace_used_tools_from_observations(observations),
        skill_call_count: 0,
        finished_at: finished_at,
        levels: trace["levels"],
        tags: tags
      }
    end
  end

  def run_trace_summary(_trace), do: nil

  @spec run_trace_detail(String.t(), keyword()) :: map() | nil
  def run_trace_detail(run_id, opts \\ []) when is_binary(run_id) do
    trace = run_trace(run_id, opts)
    observations = trace["observations"]

    if observations == [] do
      nil
    else
      tool_activity = trace_tool_activity_from_observations(observations)
      llm_turns = trace_llm_turns_from_observations(observations)

      %{
        run_id: run_id,
        prompt: nil,
        channel: trace_context(observations, "channel"),
        chat_id: trace_context(observations, "chat_id"),
        inserted_at: trace["started_at"] || (List.first(observations) || %{})["timestamp"],
        status: trace_status(trace),
        result: nil,
        selected_packages: [],
        runtime_system_messages: [],
        events: observations,
        observations: observations,
        levels: trace["levels"],
        tags: trace["tags"],
        available_tools: [],
        tool_activity: tool_activity,
        used_tools: trace_used_tools(tool_activity),
        llm_turns: llm_turns,
        tool_count: length(tool_activity),
        llm_rounds: Enum.count(llm_turns),
        path: nil
      }
    end
  end

  @spec recent_run_traces(keyword()) :: [map()]
  def recent_run_traces(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    %{"limit" => Keyword.get(opts, :observation_limit, 500)}
    |> query(opts)
    |> Enum.reverse()
    |> Enum.map(&get_in(&1, ["context", "run_id"]))
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.take(limit)
    |> Enum.map(&run_trace(&1, opts))
  end

  @spec recent_run_trace_summaries(keyword()) :: [map()]
  def recent_run_trace_summaries(opts \\ []) do
    opts
    |> recent_run_traces()
    |> Enum.map(&run_trace_summary/1)
    |> Enum.reject(&is_nil/1)
  end

  defp summarize_attrs(attrs) do
    attrs
    |> Redactor.redact()
    |> Store.stringify_keys()
    |> truncate_value()
  end

  defp truncate_value(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, truncate_value(value)} end)
  end

  defp truncate_value(list) when is_list(list), do: Enum.map(list, &truncate_value/1)

  defp truncate_value(value) when is_binary(value) do
    if String.length(value) > @summary_limit do
      String.slice(value, 0, @summary_limit) <> "...[truncated]"
    else
      value
    end
  end

  defp truncate_value(value), do: value

  defp maybe_put_filter(filters, _key, nil), do: filters
  defp maybe_put_filter(filters, _key, ""), do: filters
  defp maybe_put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp started_at(observations) do
    observations
    |> Enum.find(&String.ends_with?(to_string(&1["tag"]), ".started"))
    |> timestamp()
  end

  defp finished_at(observations) do
    observations
    |> Enum.reverse()
    |> Enum.find(fn observation ->
      tag = to_string(observation["tag"])

      String.ends_with?(tag, ".finished") or String.ends_with?(tag, ".failed") or
        String.ends_with?(tag, ".cancelled") or String.ends_with?(tag, ".completed")
    end)
    |> timestamp()
  end

  defp timestamp(nil), do: nil
  defp timestamp(observation), do: observation["timestamp"]

  defp trace_status(%{"tags" => tags}) do
    cond do
      Map.get(tags || %{}, "runner.run.failed", 0) > 0 -> "failed"
      Map.get(tags || %{}, "runner.run.finished", 0) > 0 -> "completed"
      true -> "running"
    end
  end

  defp trace_context(observations, key) do
    observations
    |> Enum.find_value(fn observation -> get_in(observation, ["context", key]) end)
  end

  defp trace_tool_activity_from_observations(observations) do
    observations
    |> Enum.filter(&(&1["tag"] in ["runner.tool.call.finished", "runner.tool.call.failed"]))
    |> Enum.map(fn observation ->
      attrs = observation["attrs_summary"] || %{}

      %{
        tool_call_id: get_in(observation, ["context", "tool_call_id"]),
        name: attrs["tool_name"],
        kind: if(trace_skill_tool_name?(attrs["tool_name"]), do: :skill, else: :tool),
        iteration: attrs["iteration"],
        inserted_at: observation["timestamp"],
        arguments: attrs["args_summary"],
        result: attrs["result_status"],
        result_inserted_at: observation["timestamp"]
      }
    end)
  end

  defp trace_used_tools_from_observations(observations) do
    observations
    |> trace_tool_activity_from_observations()
    |> trace_used_tools()
  end

  defp trace_llm_turns_from_observations(observations) do
    observations
    |> Enum.filter(&(&1["tag"] in ["runner.llm.call.finished", "runner.llm.call.failed"]))
    |> Enum.map(fn observation ->
      attrs = observation["attrs_summary"] || %{}

      %{
        iteration: attrs["iteration"],
        inserted_at: observation["timestamp"],
        message_count: nil,
        available_tool_names: [],
        tool_choice: nil,
        content: nil,
        tool_calls: [],
        finish_reason: attrs["finish_reason"],
        duration_ms: attrs["duration_ms"],
        request: nil,
        response: observation
      }
    end)
  end

  defp trace_used_tools(activity) do
    activity
    |> Enum.map(& &1.name)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  defp trace_skill_tool_name?(_name), do: false

  defp count_by(observations, key) do
    observations
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
