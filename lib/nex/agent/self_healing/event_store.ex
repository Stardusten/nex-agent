defmodule Nex.Agent.SelfHealing.EventStore do
  @moduledoc false

  require Logger

  alias Nex.Agent.Workspace

  @max_evidence_text 1_000
  @default_phase "runtime"
  @default_severity "error"

  @type event :: %{required(String.t()) => term()}

  @spec append(map(), keyword()) :: {:ok, event()} | {:error, term()}
  def append(event, opts \\ []) when is_map(event) do
    normalized = normalize_event(event, opts)
    path = events_path(workspace: Map.fetch!(normalized, "workspace"))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(normalized) <> "\n", [:append]) do
      {:ok, normalized}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  @spec recent(non_neg_integer(), keyword()) :: [event()]
  def recent(limit) when is_integer(limit) and limit >= 0 do
    recent(limit, [])
  end

  def recent(limit, opts) when is_integer(limit) and limit >= 0 do
    path = events_path(opts)

    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_line/1)
        |> Enum.take(-limit)

      {:error, _reason} ->
        []
    end
  rescue
    e ->
      Logger.warning("[SelfHealing.EventStore] recent failed: #{Exception.message(e)}")
      []
  end

  @spec events_path(keyword()) :: String.t()
  def events_path(opts \\ []) do
    Path.join([workspace_root(opts), "self_healing", "runtime_events.jsonl"])
  end

  @spec energy_path(keyword()) :: String.t()
  def energy_path(opts \\ []) do
    Path.join([workspace_root(opts), "self_healing", "energy.json"])
  end

  @spec normalize_event(map(), keyword()) :: event()
  def normalize_event(event, opts \\ []) when is_map(event) do
    event = stringify_keys(event)
    workspace = Path.expand(Map.get(event, "workspace") || workspace_root(opts))

    %{
      "id" => Map.get(event, "id") || new_id(),
      "timestamp" => Map.get(event, "timestamp") || timestamp(),
      "name" => Map.get(event, "name") |> to_string(),
      "phase" => Map.get(event, "phase") || @default_phase,
      "severity" => Map.get(event, "severity") || @default_severity,
      "run_id" => Map.get(event, "run_id") || Keyword.get(opts, :run_id),
      "session_key" => Map.get(event, "session_key") || Keyword.get(opts, :session_key),
      "workspace" => workspace,
      "actor" => Map.get(event, "actor", %{}) |> stringify_keys(),
      "classifier" => Map.get(event, "classifier", %{}) |> stringify_keys(),
      "evidence" => Map.get(event, "evidence", %{}) |> stringify_keys() |> trim_evidence(),
      "energy_cost" => normalize_cost(Map.get(event, "energy_cost", 0)),
      "decision" => Map.get(event, "decision"),
      "outcome" => Map.get(event, "outcome")
    }
  end

  defp workspace_root(opts) do
    opts
    |> Keyword.get(:workspace)
    |> case do
      nil -> Workspace.root()
      workspace -> workspace
    end
    |> Path.expand()
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) -> [event]
      _ -> []
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_keys(_), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp trim_evidence(evidence) do
    Map.new(evidence, fn {key, value} -> {key, trim_value(value)} end)
  end

  defp trim_value(value) when is_binary(value), do: String.slice(value, 0, @max_evidence_text)
  defp trim_value(value) when is_map(value), do: value |> stringify_keys() |> trim_evidence()
  defp trim_value(value) when is_list(value), do: Enum.map(value, &trim_value/1)
  defp trim_value(value), do: value

  defp normalize_cost(cost) when is_integer(cost) and cost >= 0, do: cost
  defp normalize_cost(_), do: 0

  defp new_id do
    "evt_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
