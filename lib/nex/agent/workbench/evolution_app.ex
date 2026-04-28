defmodule Nex.Agent.Workbench.EvolutionApp do
  @moduledoc false

  alias Nex.Agent.ControlPlane.{Log, Query}
  alias Nex.Agent.Evolution
  alias Nex.Agent.Tool.EvolutionCandidate
  require Log

  @app_id "self-evolution"
  @evidence_limit 500
  @candidate_limit 80

  @spec overview(keyword()) :: map()
  def overview(opts \\ []) do
    summary = Query.summary(Keyword.merge(opts, limit: 40))

    %{
      "app_id" => @app_id,
      "energy" => Map.get(summary, "budget", %{}),
      "gauges" => Map.get(summary, "gauges", %{}),
      "candidates" =>
        opts
        |> Evolution.recent_candidates()
        |> Enum.take(@candidate_limit)
        |> Enum.map(&candidate_summary/1),
      "recent" => Map.get(summary, "recent", [])
    }
  end

  @spec candidate(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def candidate(candidate_id, opts \\ []) when is_binary(candidate_id) do
    with {:ok, candidate} <- Evolution.candidate(candidate_id, opts) do
      evidence = evidence_chain(candidate["evidence_ids"] || [], opts)

      {:ok,
       candidate
       |> normalize_candidate()
       |> Map.put("evidence", evidence["observations"])
       |> Map.put("missing_evidence_ids", evidence["missing_ids"])}
    end
  end

  @spec perform_action(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def perform_action(candidate_id, action, args, opts \\ [])
      when is_binary(candidate_id) and is_binary(action) and is_map(args) do
    method = "evolution_candidate.#{action}"
    capability = "evolution:candidate:#{action}"
    attrs = action_attrs(candidate_id, action, args, method, capability)

    _ = Log.info("workbench.bridge.call.started", attrs, opts)

    case do_perform_action(candidate_id, action, args, opts) do
      {:ok, result} ->
        _ =
          Log.info(
            "workbench.bridge.call.finished",
            Map.merge(attrs, %{
              "result_status" => action_result_status(result),
              "candidate_status" => latest_candidate_status(candidate_id, opts, result)
            }),
            opts
          )

        {:ok, result}

      {:error, reason} ->
        _ =
          Log.error(
            "workbench.bridge.call.failed",
            Map.merge(attrs, %{"error_summary" => bounded(reason)}),
            opts
          )

        {:error, reason}
    end
  end

  defp do_perform_action(candidate_id, action, args, opts) do
    with :ok <- ensure_confirmed(args),
         {:ok, tool_args} <- tool_args(candidate_id, action, args) do
      case EvolutionCandidate.execute(tool_args, tool_ctx(opts)) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, to_string(reason)}
      end
    end
  end

  defp tool_args(candidate_id, "approve", args) do
    {:ok,
     %{
       "action" => "approve",
       "candidate_id" => candidate_id,
       "mode" => "plan",
       "decision_reason" => decision_reason(args)
     }}
  end

  defp tool_args(candidate_id, "apply", args) do
    {:ok,
     %{
       "action" => "approve",
       "candidate_id" => candidate_id,
       "mode" => "apply",
       "decision_reason" => decision_reason(args)
     }}
  end

  defp tool_args(candidate_id, "discard", args) do
    {:ok,
     %{
       "action" => "reject",
       "candidate_id" => candidate_id,
       "decision_reason" => decision_reason(args)
     }}
  end

  defp tool_args(_candidate_id, action, _args) do
    {:error, "unsupported evolution action: #{action}"}
  end

  defp ensure_confirmed(%{"confirm" => true}), do: :ok

  defp ensure_confirmed(_args) do
    {:error, "confirmation is required for evolution candidate actions"}
  end

  defp candidate_summary(candidate) do
    candidate
    |> Map.take([
      "candidate_id",
      "kind",
      "summary",
      "risk",
      "status",
      "evidence_ids",
      "proposed_at",
      "decided_at",
      "applied_at",
      "latest_error",
      "latest_lifecycle_tag"
    ])
    |> Map.put("created_at", candidate["created_at"] || candidate["proposed_at"])
  end

  defp normalize_candidate(candidate) do
    candidate
    |> Map.put_new("created_at", candidate["proposed_at"])
    |> Map.update("lifecycle", [], &Enum.map(&1, fn entry -> Map.drop(entry, ["attrs"]) end))
  end

  defp evidence_chain([], _opts), do: %{"observations" => [], "missing_ids" => []}

  defp evidence_chain(ids, opts) do
    ids = ids |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    observations =
      %{"id" => ids, "limit" => min(max(length(ids), 1), @evidence_limit)}
      |> Query.query(opts)
      |> Enum.map(&Query.observation_summary/1)

    observations_by_id = Map.new(observations, &{&1["id"], &1})

    found = observations_by_id |> Map.keys() |> MapSet.new()

    %{
      "observations" => Enum.flat_map(ids, &List.wrap(Map.get(observations_by_id, &1))),
      "missing_ids" => Enum.reject(ids, &MapSet.member?(found, &1))
    }
  end

  defp action_attrs(candidate_id, action, args, method, capability) do
    %{
      "app_id" => @app_id,
      "method" => method,
      "capability" => capability,
      "candidate_id" => candidate_id,
      "action" => action,
      "decision_reason" => decision_reason(args)
    }
    |> compact()
  end

  defp tool_ctx(opts) do
    %{
      workspace: Keyword.get(opts, :workspace),
      session_key: "workbench:self-evolution",
      channel: "workbench"
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp decision_reason(args) do
    args
    |> Map.get("decision_reason", Map.get(args, "reason", ""))
    |> bounded(240)
  end

  defp action_result_status(%{"apply" => %{"status" => status}}), do: status
  defp action_result_status(%{"decision" => decision}), do: decision
  defp action_result_status(_result), do: "ok"

  defp latest_candidate_status(candidate_id, opts, fallback) do
    case Evolution.candidate(candidate_id, opts) do
      {:ok, %{"status" => status}} -> status
      _ -> result_candidate_status(fallback)
    end
  end

  defp result_candidate_status(%{"candidate" => %{"status" => status}}), do: status
  defp result_candidate_status(_result), do: nil

  defp bounded(value, limit \\ 500) do
    value = to_string(value)

    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "...[truncated]"
    else
      value
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
