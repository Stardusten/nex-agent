defmodule Nex.Agent.SelfHealing.EnergyLedger do
  @moduledoc false

  require Logger

  alias Nex.Agent.SelfHealing.EventStore

  @capacity 100
  @initial_current 60
  @refill_rate 10
  @refill_interval_seconds 60 * 60

  @type mode :: :sleep | :low | :normal | :deep
  @type ledger :: %{
          required(String.t()) => non_neg_integer() | String.t()
        }

  @spec current(keyword()) :: ledger()
  def current(opts \\ []) do
    path = EventStore.energy_path(opts)

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, ledger} when is_map(ledger) ->
            ledger
            |> normalize_ledger()
            |> maybe_refill(opts)

          _ ->
            init(opts)
        end

      {:error, _reason} ->
        init(opts)
    end
  rescue
    e ->
      Logger.warning("[SelfHealing.EnergyLedger] current failed: #{Exception.message(e)}")
      default_ledger()
  end

  @spec spend(atom() | String.t(), non_neg_integer(), keyword()) ::
          {:ok, ledger()} | {:error, :insufficient_energy}
  def spend(_action, cost, opts \\ []) when is_integer(cost) and cost >= 0 do
    ledger = current(opts)
    available = Map.fetch!(ledger, "current")

    if available >= cost do
      updated =
        ledger
        |> Map.put("current", available - cost)
        |> Map.update!("spent_today", &(&1 + cost))
        |> put_mode()

      :ok = persist(updated, opts)
      {:ok, updated}
    else
      {:error, :insufficient_energy}
    end
  end

  @spec mode(map()) :: mode()
  def mode(%{"current" => current}), do: mode_for_current(current)
  def mode(%{current: current}), do: mode_for_current(current)
  def mode(_), do: :sleep

  @spec init(keyword()) :: ledger()
  def init(opts \\ []) do
    ledger = default_ledger()
    _ = persist(ledger, opts)
    ledger
  end

  defp persist(ledger, opts) do
    path = EventStore.energy_path(opts)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(ledger, pretty: true)) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[SelfHealing.EnergyLedger] persist failed: #{inspect(reason)}")
        :ok
    end
  end

  defp default_ledger do
    %{
      "capacity" => @capacity,
      "current" => @initial_current,
      "mode" => Atom.to_string(mode_for_current(@initial_current)),
      "refill_rate" => @refill_rate,
      "last_refilled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "spent_today" => 0
    }
  end

  defp normalize_ledger(ledger) do
    capacity =
      ledger
      |> Map.get("capacity", @capacity)
      |> normalize_non_neg(@capacity)

    current =
      ledger
      |> Map.get("current", @initial_current)
      |> normalize_non_neg(@initial_current)
      |> min(capacity)

    %{
      "capacity" => capacity,
      "current" => current,
      "mode" => Atom.to_string(mode_for_current(current)),
      "refill_rate" =>
        Map.get(ledger, "refill_rate", @refill_rate) |> normalize_non_neg(@refill_rate),
      "last_refilled_at" =>
        Map.get(ledger, "last_refilled_at") || DateTime.utc_now() |> DateTime.to_iso8601(),
      "spent_today" => Map.get(ledger, "spent_today", 0) |> normalize_non_neg(0)
    }
  end

  defp maybe_refill(ledger, opts) do
    refilled = refill(ledger, DateTime.utc_now())

    if refilled == ledger do
      ledger
    else
      _ = persist(refilled, opts)
      refilled
    end
  end

  defp refill(%{"last_refilled_at" => timestamp} = ledger, now) do
    with {:ok, last_refilled_at, _offset} <- DateTime.from_iso8601(timestamp) do
      elapsed_seconds = max(DateTime.diff(now, last_refilled_at, :second), 0)
      refill_units = div(elapsed_seconds, @refill_interval_seconds)
      refill_amount = refill_units * ledger["refill_rate"]

      apply_refill(ledger, refill_amount, now)
    else
      _ -> ledger
    end
  end

  defp refill(ledger, _now), do: ledger

  defp apply_refill(ledger, refill_amount, _now) when refill_amount <= 0, do: ledger

  defp apply_refill(ledger, refill_amount, now) do
    current = min(ledger["capacity"], ledger["current"] + refill_amount)

    ledger
    |> Map.put("current", current)
    |> Map.put("last_refilled_at", DateTime.to_iso8601(now))
    |> put_mode()
  end

  defp put_mode(ledger) do
    Map.put(ledger, "mode", ledger |> mode() |> Atom.to_string())
  end

  defp mode_for_current(0), do: :sleep
  defp mode_for_current(current) when current < 20, do: :low
  defp mode_for_current(current) when current < 70, do: :normal
  defp mode_for_current(_current), do: :deep

  defp normalize_non_neg(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg(_value, default), do: default
end
