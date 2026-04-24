defmodule Nex.Agent.SelfHealing.Router do
  @moduledoc false

  require Logger

  alias Nex.Agent.SelfHealing.{Aggregator, EnergyLedger, EventStore}

  @aggregate_cost 1
  @hint_cost 2
  @reflect_cost 8

  @type action :: :record_only | :hint_candidate | :reflect_candidate
  @type decision :: %{
          action: action(),
          reason: String.t(),
          energy_mode: EnergyLedger.mode(),
          energy_spent: non_neg_integer(),
          summary: String.t() | nil
        }

  @spec decide(map(), Aggregator.summary(), keyword()) :: decision()
  def decide(event, aggregation, opts \\ []) do
    ledger = EnergyLedger.current(opts)
    mode = EnergyLedger.mode(ledger)

    {action, reason, cost} = candidate(mode, event, aggregation)

    cond do
      action == :record_only ->
        decision(action, reason, mode, 0, aggregation)

      ledger["current"] < @aggregate_cost ->
        decision(:record_only, "insufficient energy for aggregation", mode, 0, aggregation)

      ledger["current"] < cost ->
        decision(:record_only, "insufficient energy for #{action}", mode, 0, aggregation)

      true ->
        case EnergyLedger.spend(action, cost, opts) do
          {:ok, _updated} ->
            decision(action, reason, mode, cost, aggregation)

          {:error, :insufficient_energy} ->
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
    normalized = EventStore.normalize_event(event, opts)
    recent = EventStore.recent(20, workspace: Map.fetch!(normalized, "workspace"))
    aggregation = Aggregator.summarize(%{event: normalized, recent_events: recent})
    decision = decide(normalized, aggregation, workspace: Map.fetch!(normalized, "workspace"))

    normalized
    |> Map.put("decision", stringify_decision(decision))
    |> Map.put("energy_cost", decision.energy_spent)
    |> EventStore.append(workspace: Map.fetch!(normalized, "workspace"))
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
end
