defmodule Nex.Agent.SelfHealing.Router do
  @moduledoc false

  require Logger

  alias Nex.Agent.ControlPlane.{Budget, Log, Query}
  alias Nex.Agent.SelfHealing.Aggregator
  alias Nex.Agent.Workspace
  require Log

  @aggregate_cost 1
  @hint_cost 2
  @reflect_cost 8

  @type action :: :record_only | :hint_candidate | :reflect_candidate
  @type decision :: %{
          action: action(),
          reason: String.t(),
          energy_mode: :sleep | :low | :normal | :deep,
          energy_spent: non_neg_integer(),
          summary: String.t() | nil
        }

  @spec decide(map(), Aggregator.summary(), keyword()) :: decision()
  def decide(event, aggregation, opts \\ []) do
    ledger = Budget.current(opts)
    mode = Budget.mode(ledger)

    {action, reason, cost} = candidate(mode, event, aggregation)

    cond do
      action == :record_only ->
        decision(action, reason, mode, 0, aggregation)

      ledger["current"] < @aggregate_cost ->
        decision(:record_only, "insufficient energy for aggregation", mode, 0, aggregation)

      ledger["current"] < cost ->
        decision(:record_only, "insufficient energy for #{action}", mode, 0, aggregation)

      true ->
        case Budget.spend(action, cost, opts) do
          {:ok, _updated} ->
            decision(action, reason, mode, cost, aggregation)

          {:error, :insufficient_energy} ->
            decision(:record_only, "insufficient energy for #{action}", mode, 0, aggregation)

          {:error, :insufficient_budget} ->
            decision(:record_only, "insufficient energy for #{action}", mode, 0, aggregation)
        end
    end
  rescue
    e ->
      Logger.warning("[SelfHealing.Router] decide failed: #{Exception.message(e)}")
      decision(:record_only, "router failed", :sleep, 0, nil)
  end

  @spec record_event(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_event(event, opts \\ []) when is_map(event) do
    normalized = normalize_event(event, opts)
    recent = recent_events(Map.fetch!(normalized, "workspace"))
    aggregation = Aggregator.summarize(%{event: normalized, recent_events: recent})
    decision = decide(normalized, aggregation, workspace: Map.fetch!(normalized, "workspace"))

    attrs =
      normalized
      |> Map.drop(["name", "workspace", "run_id", "session_key"])
      |> Map.put("decision", stringify_decision(decision))
      |> Map.put("energy_cost", decision.energy_spent)

    opts =
      opts
      |> Keyword.put(:workspace, Map.fetch!(normalized, "workspace"))
      |> put_context_opt(:run_id, Map.get(normalized, "run_id"))
      |> put_context_opt(:session_key, Map.get(normalized, "session_key"))

    case Log.error(Map.fetch!(normalized, "name"), attrs, opts) do
      {:ok, observation} -> {:ok, Query.observation_summary(observation)}
      :ok -> {:ok, normalized |> Map.merge(attrs)}
      {:error, reason} -> {:error, reason}
      other -> {:ok, normalized |> Map.merge(attrs) |> Map.put("log_result", inspect(other))}
    end
  rescue
    e ->
      Logger.warning("[SelfHealing.Router] record_event failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp candidate(:sleep, _event, _aggregation), do: {:record_only, "energy mode sleep", 0}

  defp candidate(:low, _event, %{repeated?: true}) do
    {:hint_candidate, "repeated failure in low energy mode", @aggregate_cost + @hint_cost}
  end

  defp candidate(:low, _event, _aggregation), do: {:record_only, "low energy and not repeated", 0}

  defp candidate(mode, event, %{repeated?: repeated?})
       when mode in [:normal, :deep] do
    severity = event |> Map.get("severity", "error") |> to_string()

    if repeated? or severity == "critical" do
      {:reflect_candidate, "repeated or critical failure", @aggregate_cost + @reflect_cost}
    else
      {:record_only, "not repeated or critical", 0}
    end
  end

  defp candidate(_mode, _event, _aggregation), do: {:record_only, "no matching route", 0}

  defp recent_events(workspace) do
    Query.query(%{"limit" => 20}, workspace: workspace)
    |> Enum.filter(&(&1["level"] in ["error", "critical"]))
    |> Enum.map(&Query.observation_summary/1)
  rescue
    e ->
      Logger.warning("[SelfHealing.Router] query failed: #{Exception.message(e)}")
      []
  end

  defp normalize_event(event, opts) do
    event = stringify_keys(event)
    workspace = Path.expand(Map.get(event, "workspace") || Workspace.root(opts))

    %{
      "name" => Map.get(event, "name") |> to_string(),
      "severity" => Map.get(event, "severity") || "error",
      "run_id" => Map.get(event, "run_id") || Keyword.get(opts, :run_id),
      "session_key" => Map.get(event, "session_key") || Keyword.get(opts, :session_key),
      "workspace" => workspace,
      "actor" => Map.get(event, "actor", %{}) |> stringify_keys(),
      "classifier" => Map.get(event, "classifier", %{}) |> stringify_keys(),
      "evidence" => Map.get(event, "evidence", %{}) |> stringify_keys(),
      "outcome" => Map.get(event, "outcome")
    }
  end

  defp decision(action, reason, mode, spent, nil) do
    %{
      action: action,
      reason: reason,
      energy_mode: mode,
      energy_spent: spent,
      summary: nil
    }
  end

  defp decision(action, reason, mode, spent, aggregation) do
    %{
      action: action,
      reason: reason,
      energy_mode: mode,
      energy_spent: spent,
      summary: Map.get(aggregation, :summary)
    }
  end

  defp stringify_decision(decision) do
    %{
      "action" => decision.action |> Atom.to_string(),
      "reason" => decision.reason,
      "energy_mode" => decision.energy_mode |> Atom.to_string(),
      "energy_spent" => decision.energy_spent,
      "summary" => decision.summary
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_keys(_), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp put_context_opt(opts, _key, nil), do: opts
  defp put_context_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
