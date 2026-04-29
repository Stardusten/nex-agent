defmodule Nex.Agent.Observe.Compat.RequestTrace do
  @moduledoc false

  alias Nex.Agent.Observe.ControlPlane.{Log, Query}
  require Log

  @spec default_config() :: map()
  def default_config do
    %{"enabled" => false}
  end

  @spec config(keyword()) :: map()
  def config(opts \\ []) do
    Map.merge(default_config(), Keyword.get(opts, :request_trace, %{}))
  end

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    config(opts)["enabled"] == true
  end

  @spec append_event(map(), keyword()) :: {:ok, String.t()} | :ok | {:error, String.t()}
  def append_event(event, opts \\ []) when is_map(event) do
    run_id = event[:run_id] || event["run_id"]

    if is_binary(run_id) and run_id != "" do
      type = event[:type] || event["type"] || "event"

      attrs =
        event_summary(type, event)
        |> Map.put_new(:inserted_at, DateTime.utc_now() |> DateTime.to_iso8601())
        |> sanitize_value()

      case Log.info("request_trace.event.recorded", attrs, Keyword.put(opts, :run_id, run_id)) do
        {:ok, _observation} -> {:ok, run_id}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      {:error, "request trace event missing run_id"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @spec list_paths(keyword()) :: [String.t()]
  def list_paths(opts \\ []) do
    opts
    |> Keyword.put_new(:limit, Keyword.get(opts, :limit, 100))
    |> Query.recent_run_traces()
    |> Enum.map(& &1["run_id"])
  end

  @spec read_trace(String.t(), keyword()) :: [map()]
  def read_trace(identifier, opts \\ []) when is_binary(identifier) do
    run_id = identifier |> Path.basename() |> String.replace_suffix(".jsonl", "")

    %{"observations" => observations} = Query.run_trace(run_id, opts)

    observations
    |> Enum.map(&trace_event_from_observation(&1, run_id))
  end

  defp trace_event_from_observation(
         %{"tag" => "request_trace.event.recorded"} = observation,
         run_id
       ) do
    observation
    |> Map.get("attrs_summary", %{})
    |> Map.put_new("run_id", run_id)
    |> Map.put_new("inserted_at", observation["timestamp"])
  end

  defp trace_event_from_observation(observation, run_id) do
    attrs = Map.get(observation, "attrs_summary", %{})

    %{
      "type" => Map.get(observation, "tag"),
      "run_id" => run_id,
      "inserted_at" => Map.get(observation, "timestamp"),
      "level" => Map.get(observation, "level"),
      "tag" => Map.get(observation, "tag"),
      "context" => Map.get(observation, "context", %{}),
      "attrs_summary" => attrs
    }
    |> Map.merge(legacy_trace_fields(attrs))
  end

  defp legacy_trace_fields(attrs) do
    attrs
    |> Map.take([
      "content_summary",
      "duration_ms",
      "finish_reason",
      "iteration",
      "prompt_summary",
      "result_summary",
      "status",
      "tool",
      "tool_call_id"
    ])
  end

  defp sanitize_value(%_{} = struct), do: struct |> Map.from_struct() |> sanitize_value()

  defp sanitize_value(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), sanitize_value(v)} end)

  defp sanitize_value(list) when is_list(list), do: Enum.map(list, &sanitize_value/1)

  defp sanitize_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp sanitize_value(value),
    do: inspect(value, pretty: false, limit: :infinity, printable_limit: 100_000)

  defp event_summary(type, event) do
    %{
      "type" => to_string(type),
      "run_id" => event[:run_id] || event["run_id"],
      "prompt_summary" => text_summary(event[:prompt] || event["prompt"]),
      "content_summary" => text_summary(event[:content] || event["content"]),
      "result_summary" => text_summary(event[:result] || event["result"]),
      "status" => event[:status] || event["status"],
      "iteration" => event[:iteration] || event["iteration"],
      "tool" => event[:tool] || event["tool"],
      "tool_call_id" => event[:tool_call_id] || event["tool_call_id"],
      "duration_ms" => event[:duration_ms] || event["duration_ms"],
      "finish_reason" => event[:finish_reason] || event["finish_reason"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp text_summary(nil), do: nil

  defp text_summary(value) do
    value
    |> to_string()
    |> String.slice(0, 1000)
  end
end
