defmodule Nex.Agent.Tool.EvolutionCandidate do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.ControlPlane.Log
  alias Nex.Agent.Evolution.{Candidates, Executor}
  require Log

  @approve_actions ~w(list show approve reject)
  @terminal_statuses ~w(rejected applied superseded)

  def name, do: "evolution_candidate"

  def description do
    "List, inspect, approve, or reject owner-approved evolution candidates derived from ControlPlane lifecycle observations."
  end

  def category, do: :evolution

  def definition do
    definition(:all)
  end

  def definition(:subagent), do: hidden_definition()
  def definition(:follow_up), do: hidden_definition()

  def definition(_surface) do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: @approve_actions,
            description:
              "list candidates, show one candidate, or record an owner approval/rejection"
          },
          candidate_id: %{
            type: "string",
            description: "Candidate id returned from evolution candidate list/show"
          },
          decision_reason: %{
            type: "string",
            description: "Owner rationale for approve/reject decisions"
          },
          mode: %{
            type: "string",
            enum: ["plan", "apply"],
            description:
              "Execution mode. approve defaults to apply except code_hint defaults to plan."
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(%{"action" => "list"}, ctx) do
    {:ok, %{"candidates" => Candidates.list(tool_opts(ctx))}}
  end

  def execute(%{"action" => "show", "candidate_id" => candidate_id}, ctx) do
    with {:ok, candidate} <- Candidates.get(candidate_id, tool_opts(ctx)) do
      {:ok, candidate}
    end
  end

  def execute(%{"action" => "approve", "candidate_id" => candidate_id} = args, ctx) do
    with {:ok, candidate} <- Candidates.get(candidate_id, tool_opts(ctx)),
         :ok <- ensure_actionable(candidate, "approve") do
      mode = approval_mode(candidate, Map.get(args, "mode"))

      attrs =
        %{
          "candidate_id" => candidate_id,
          "kind" => candidate["kind"],
          "summary" => candidate["summary"],
          "mode" => mode,
          "decision_reason" => Map.get(args, "decision_reason"),
          "status_before" => candidate["status"]
        }
        |> compact_map()

      case Log.info("evolution.candidate.approved", attrs, tool_opts(ctx)) do
        {:ok, observation} ->
          continue_approval(candidate, mode, observation["id"], ctx)

        :ok ->
          continue_approval(candidate, mode, nil, ctx)

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  def execute(%{"action" => "reject", "candidate_id" => candidate_id} = args, ctx) do
    with {:ok, candidate} <- Candidates.get(candidate_id, tool_opts(ctx)),
         :ok <- ensure_actionable(candidate, "reject") do
      attrs =
        %{
          "candidate_id" => candidate_id,
          "kind" => candidate["kind"],
          "summary" => candidate["summary"],
          "decision_reason" => Map.get(args, "decision_reason"),
          "status_before" => candidate["status"]
        }
        |> compact_map()

      case Log.info("evolution.candidate.rejected", attrs, tool_opts(ctx)) do
        {:ok, observation} ->
          {:ok,
           %{
             "candidate" => candidate,
             "decision" => "rejected",
             "observation_id" => observation["id"]
           }}

        :ok ->
          {:ok, %{"candidate" => candidate, "decision" => "rejected"}}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  def execute(%{"action" => "show"}, _ctx), do: {:error, "candidate_id is required"}
  def execute(%{"action" => "approve"}, _ctx), do: {:error, "candidate_id is required"}
  def execute(%{"action" => "reject"}, _ctx), do: {:error, "candidate_id is required"}
  def execute(_args, _ctx), do: {:error, "action must be one of list/show/approve/reject"}

  defp continue_approval(candidate, mode, observation_id, ctx) do
    case Executor.realize(candidate, mode, ctx) do
      {:ok, realization} ->
        with {:ok, realization_observation_id} <-
               emit_realization(candidate, mode, realization, ctx),
             {:ok, apply_result} <- maybe_apply(candidate, mode, realization, ctx) do
          {:ok,
           %{
             "candidate" => candidate,
             "decision" => "approved",
             "mode" => mode,
             "observation_id" => observation_id,
             "realization_observation_id" => realization_observation_id,
             "apply" => apply_result
           }}
        end

      {:error, reason} ->
        _ =
          Log.error(
            "evolution.candidate.realization.failed",
            %{
              "candidate_id" => candidate["candidate_id"],
              "kind" => candidate["kind"],
              "mode" => mode,
              "error_summary" => inspect(reason)
            },
            tool_opts(ctx)
          )

        {:error, inspect(reason)}
    end
  end

  defp hidden_definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["list", "show"],
            description:
              "This tool is owner-only; follow-up and subagent surfaces do not expose it."
          }
        },
        required: ["action"]
      }
    }
  end

  defp ensure_actionable(%{"status" => status}, action) when status in @terminal_statuses do
    {:error, "Cannot #{action} candidate in status #{status}"}
  end

  defp ensure_actionable(%{"status" => "pending"}, _action), do: :ok

  defp ensure_actionable(%{"status" => "approved"}, action),
    do: {:error, "Candidate already approved; cannot #{action}"}

  defp ensure_actionable(%{"status" => "failed"}, action),
    do: {:error, "Candidate already failed; cannot #{action} before retry support exists"}

  defp ensure_actionable(%{"status" => "realized"}, action),
    do: {:error, "Candidate already realized; cannot #{action}"}

  defp ensure_actionable(candidate, action),
    do: {:error, "Cannot #{action} candidate in status #{candidate["status"] || "unknown"}"}

  defp approval_mode(%{"kind" => "code_hint"}, nil), do: "plan"
  defp approval_mode(_candidate, nil), do: "apply"
  defp approval_mode(_candidate, mode) when mode in ["plan", "apply"], do: mode
  defp approval_mode(candidate, _mode), do: approval_mode(candidate, nil)

  defp tool_opts(ctx) when is_map(ctx) do
    []
    |> put_opt(:workspace, ctx)
    |> put_opt(:run_id, ctx)
    |> put_opt(:session_key, ctx)
    |> put_opt(:channel, ctx)
    |> put_opt(:chat_id, ctx)
    |> put_opt(:tool_call_id, ctx)
    |> put_opt(:trace_id, ctx)
  end

  defp tool_opts(_ctx), do: []

  defp emit_realization(candidate, mode, realization, ctx) do
    attrs =
      %{
        "candidate_id" => candidate["candidate_id"],
        "kind" => candidate["kind"],
        "mode" => mode,
        "summary" => realization["summary"],
        "execution" => realization["execution"]
      }
      |> compact_map()

    case Log.info("evolution.candidate.realization.generated", attrs, tool_opts(ctx)) do
      {:ok, observation} -> {:ok, observation["id"]}
      :ok -> {:ok, nil}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp maybe_apply(candidate, "apply", realization, ctx) do
    with {:ok, started_id} <- emit_apply_started(candidate, realization, ctx) do
      case Executor.apply_realization(realization, ctx) do
        {:ok, applied_realization} ->
          attrs = %{
            "candidate_id" => candidate["candidate_id"],
            "kind" => candidate["kind"],
            "mode" => "apply",
            "summary" => candidate["summary"],
            "result_summary" =>
              inspect(applied_realization["result"], limit: 20, printable_limit: 400)
          }

          case Log.info("evolution.candidate.apply.completed", compact_map(attrs), tool_opts(ctx)) do
            {:ok, observation} ->
              {:ok,
               %{
                 "status" => "applied",
                 "started_observation_id" => started_id,
                 "completed_observation_id" => observation["id"]
               }}

            :ok ->
              {:ok, %{"status" => "applied", "started_observation_id" => started_id}}

            {:error, reason} ->
              {:error, inspect(reason)}
          end

        {:error, reason} ->
          _ =
            Log.error(
              "evolution.candidate.apply.failed",
              compact_map(%{
                "candidate_id" => candidate["candidate_id"],
                "kind" => candidate["kind"],
                "mode" => "apply",
                "error_summary" => inspect(reason)
              }),
              tool_opts(ctx)
            )

          {:error, inspect(reason)}
      end
    end
  end

  defp maybe_apply(candidate, "plan", _realization, _ctx) do
    {:ok, %{"status" => "planned", "candidate_id" => candidate["candidate_id"]}}
  end

  defp emit_apply_started(candidate, realization, ctx) do
    attrs =
      %{
        "candidate_id" => candidate["candidate_id"],
        "kind" => candidate["kind"],
        "mode" => "apply",
        "summary" => candidate["summary"],
        "execution" => realization["execution"]
      }
      |> compact_map()

    case Log.info("evolution.candidate.apply.started", attrs, tool_opts(ctx)) do
      {:ok, observation} -> {:ok, observation["id"]}
      :ok -> {:ok, nil}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp put_opt(opts, key, ctx) do
    case Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key)) do
      nil -> opts
      value -> Keyword.put(opts, key, value)
    end
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
