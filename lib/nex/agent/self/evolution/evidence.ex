defmodule Nex.Agent.Self.Evolution.Evidence do
  @moduledoc false

  alias Nex.Agent.Observe.ControlPlane.{Budget, Gauge, Query}
  alias Nex.Agent.Self.Healing.Aggregator
  require Nex.Agent.Observe.ControlPlane.Log

  @quick_limit 30
  @routine_limit 100
  @deep_limit 500
  @candidate_history_limit 20

  @spec build(atom(), atom(), keyword()) :: {:ok, map()}
  def build(trigger, requested_profile, opts \\ []) do
    budget = Budget.current(opts)
    budget_mode = Budget.mode(budget)
    profile = requested_profile
    window = build_window(profile, budget_mode, opts)

    observations =
      %{"since" => window["since"], "limit" => window["limit"]}
      |> Query.query(opts)
      |> Enum.filter(&include_in_evidence?/1)
      |> Enum.map(&Query.observation_summary/1)
      |> Enum.reverse()

    patterns = Aggregator.patterns(observations)
    current_runs = current_runs(opts)
    candidate_history = recent_candidate_history(window, opts)

    Enum.each(patterns, fn pattern ->
      Nex.Agent.Observe.ControlPlane.Log.info(
        "evolution.pattern.detected",
        %{
          "tag" => pattern["tag"],
          "count" => pattern["count"],
          "severity" => pattern["severity"],
          "actors" => pattern["actors"],
          "sample_ids" => pattern["sample_ids"]
        },
        opts
      )
    end)

    {:ok,
     %{
       "trigger" => Atom.to_string(trigger),
       "profile" => Atom.to_string(profile),
       "budget" => %{
         "mode" => Atom.to_string(budget_mode),
         "current" => budget["current"],
         "capacity" => budget["capacity"]
       },
       "window" => window,
       "observations" => observations,
       "patterns" => patterns,
       "current_runs" => current_runs,
       "candidate_history" => candidate_history
     }}
  end

  defp build_window(profile, budget_mode, opts) do
    limit =
      case {profile, budget_mode} do
        {:quick, _} -> @quick_limit
        {:routine, _} -> @routine_limit
        {:deep, :deep} -> @deep_limit
        {:deep, _} -> @routine_limit
      end

    since =
      case Keyword.get(opts, :since) do
        since when is_binary(since) and since != "" ->
          since

        _ ->
          hours =
            case {profile, budget_mode} do
              {:quick, _} -> 12
              {:routine, _} -> 72
              {:deep, :deep} -> 24 * 14
              {:deep, _} -> 72
            end

          DateTime.utc_now() |> DateTime.add(-hours, :hour) |> DateTime.to_iso8601()
      end

    %{"since" => since, "limit" => limit}
  end

  defp current_runs(opts) do
    case Gauge.current("run.owner.current", opts) do
      %{"value" => %{"owners" => owners}} when is_list(owners) -> owners
      %{"attrs" => attrs} when is_map(attrs) -> [attrs]
      _ -> []
    end
  end

  defp recent_candidate_history(window, opts) do
    %{
      "tag" => "evolution.candidate.proposed",
      "since" => window["since"],
      "limit" => @candidate_history_limit
    }
    |> Query.query(opts)
    |> Enum.map(&candidate_history_entry/1)
    |> Enum.reverse()
  end

  defp candidate_history_entry(observation) do
    summary = Query.observation_summary(observation)

    %{
      "id" => summary["id"],
      "timestamp" => summary["timestamp"],
      "kind" => get_in(summary, ["attrs_summary", "kind"]),
      "summary" => get_in(summary, ["attrs_summary", "summary"]),
      "risk" => get_in(summary, ["attrs_summary", "risk"]),
      "evidence_ids" => get_in(summary, ["attrs_summary", "evidence_ids"]) || []
    }
  end

  defp include_in_evidence?(%{"tag" => "evolution.signal.recorded"}), do: true
  defp include_in_evidence?(%{"level" => level}), do: level in ["warning", "error", "critical"]
  defp include_in_evidence?(_), do: false
end
