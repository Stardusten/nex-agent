defmodule Nex.Agent.Observe.ControlPlane.Budget do
  @moduledoc false

  require Nex.Agent.Observe.ControlPlane.Log
  require Nex.Agent.Observe.ControlPlane.Metric

  alias Nex.Agent.Observe.ControlPlane.Store

  @default %{
    "capacity" => 100,
    "current" => 60,
    "mode" => "normal",
    "refill_rate" => 10,
    "last_refilled_at" => nil,
    "spent_today" => 0
  }

  @type mode :: :sleep | :low | :normal | :deep

  @spec current(keyword()) :: map()
  def current(opts \\ []) do
    ledger =
      opts
      |> Store.budget_path()
      |> read_budget()
      |> refill()

    persist(ledger, opts)
    ledger
  rescue
    _e ->
      initialized()
  end

  @spec spend(atom() | String.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, :insufficient_budget} | {:error, term()}
  def spend(action, cost, opts \\ []) when is_integer(cost) and cost >= 0 do
    action = normalize_action(action)
    ledger = current(opts)

    if ledger["current"] < cost do
      Nex.Agent.Observe.ControlPlane.Log.warning(
        "control_plane.budget.insufficient",
        %{"action" => action, "cost" => cost, "current" => ledger["current"]},
        opts
      )

      {:error, :insufficient_budget}
    else
      updated =
        ledger
        |> Map.update!("current", &(&1 - cost))
        |> Map.update!("spent_today", &(&1 + cost))
        |> refresh_mode()

      with :ok <- persist(updated, opts) do
        Nex.Agent.Observe.ControlPlane.Metric.count(
          "control_plane.budget.spent",
          cost,
          %{"action" => action},
          opts
        )

        {:ok, updated}
      end
    end
  end

  @spec mode(map()) :: mode()
  def mode(%{"current" => current}) when current <= 0, do: :sleep
  def mode(%{"current" => current}) when current < 20, do: :low
  def mode(%{"current" => current}) when current < 80, do: :normal
  def mode(%{"current" => _current}), do: :deep
  def mode(_state), do: :sleep

  @spec budget_path(keyword()) :: String.t()
  def budget_path(opts \\ []), do: Store.budget_path(opts)

  defp read_budget(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = ledger} -> Map.merge(initialized(), ledger)
          _ -> initialized()
        end

      {:error, _reason} ->
        initialized()
    end
  end

  defp initialized do
    @default
    |> Map.put("last_refilled_at", Store.timestamp())
    |> refresh_mode()
  end

  defp refill(%{} = ledger) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    capacity = normalize_int(ledger["capacity"], 100)
    current = normalize_int(ledger["current"], 60)
    refill_rate = normalize_int(ledger["refill_rate"], 10)
    spent_today = normalize_int(ledger["spent_today"], 0)

    last_refilled_at =
      case DateTime.from_iso8601(to_string(ledger["last_refilled_at"])) do
        {:ok, datetime, _} -> datetime
        _ -> now
      end

    elapsed_seconds = max(DateTime.diff(now, last_refilled_at, :second), 0)
    elapsed_hours = div(elapsed_seconds + 3599, 3600)
    refilled = min(current + elapsed_hours * refill_rate, capacity)

    %{
      "capacity" => capacity,
      "current" => refilled,
      "mode" => ledger["mode"],
      "refill_rate" => refill_rate,
      "last_refilled_at" => DateTime.to_iso8601(now),
      "spent_today" => spent_today
    }
    |> refresh_mode()
  end

  defp refresh_mode(ledger) do
    Map.put(ledger, "mode", ledger |> mode() |> Atom.to_string())
  end

  defp persist(ledger, opts) do
    path = Store.budget_path(opts)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode!(ledger))
    end
  end

  defp normalize_action(action) when is_atom(action), do: Atom.to_string(action)
  defp normalize_action(action) when is_binary(action), do: action
  defp normalize_action(action), do: inspect(action)

  defp normalize_int(value, _default) when is_integer(value), do: value

  defp normalize_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp normalize_int(_value, default), do: default
end
