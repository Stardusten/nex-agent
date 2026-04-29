defmodule Nex.Agent.Self.Evolution do
  @moduledoc """
  Evolution consumes ControlPlane evidence and proposes bounded owner-approved candidates.
  """

  alias Nex.Agent.{Runtime.Config, Capability.Skills, Runtime.Workspace}
  alias Nex.Agent.Observe.ControlPlane.{Budget, Log, Query, Store}
  alias Nex.Agent.Self.Evolution.{Candidates, Evidence}
  require Log

  @evolution_counter_file ".evolution_counter"
  @consolidations_per_evolution 5

  @type trigger :: :manual | :post_consolidation | :scheduled_daily | :scheduled_weekly
  @type profile :: :quick | :routine | :deep

  @spec run_evolution_cycle(keyword()) :: {:ok, map()} | {:error, term()}
  def run_evolution_cycle(opts \\ []) do
    trigger = normalize_trigger(Keyword.get(opts, :trigger, :manual))
    requested_profile = profile_for_trigger(trigger)
    workspace_opts = workspace_opts(opts)

    with {:ok, evidence} <- Evidence.build(trigger, requested_profile, opts) do
      profile = evidence["profile"] |> normalize_profile()
      budget_mode = evidence["budget"]["mode"] |> normalize_budget_mode()
      run_opts = Keyword.merge(opts, resolve_runtime_llm_opts(opts))

      log_cycle(
        :info,
        "evolution.cycle.started",
        evidence,
        %{
          "trigger" => Atom.to_string(trigger),
          "profile" => Atom.to_string(profile),
          "budget_mode" => Atom.to_string(budget_mode),
          "evidence_count" => length(evidence["observations"]),
          "pattern_count" => length(evidence["patterns"])
        },
        workspace_opts
      )

      case run_cycle_with_evidence(evidence, budget_mode, run_opts) do
        {:ok, result} ->
          completed =
            result
            |> Map.take([
              :status,
              :trigger,
              :profile,
              :budget_mode,
              :evidence_count,
              :pattern_count,
              :candidate_count
            ])
            |> Map.new(fn {key, value} -> {Atom.to_string(key), stringify_value(value)} end)

          log_cycle(:info, "evolution.cycle.completed", evidence, completed, workspace_opts)
          emit_candidate_observations(result.candidates, evidence, workspace_opts)
          {:ok, result}

        {:skipped, attrs, candidates} ->
          result = skipped_result(trigger, profile, budget_mode, evidence, candidates)
          log_cycle(:info, "evolution.cycle.skipped", evidence, attrs, workspace_opts)
          emit_candidate_observations(candidates, evidence, workspace_opts)
          {:ok, result}

        {:error, reason} = err ->
          log_cycle(
            :error,
            "evolution.cycle.failed",
            evidence,
            %{
              "trigger" => Atom.to_string(trigger),
              "profile" => Atom.to_string(profile),
              "budget_mode" => Atom.to_string(budget_mode),
              "reason_type" => reason_type(reason),
              "error_summary" => error_summary(reason)
            },
            workspace_opts
          )

          err
      end
    end
  end

  @spec record_signal(map(), keyword()) :: :ok
  def record_signal(signal, opts \\ []) when is_map(signal) do
    attrs =
      %{
        "source" => Map.get(signal, :source, Map.get(signal, "source", "unknown")) |> to_string(),
        "signal" => Map.get(signal, :signal, Map.get(signal, "signal", "")) |> to_string(),
        "context" => Map.get(signal, :context, Map.get(signal, "context", %{})),
        "recorded_at" => Store.timestamp()
      }
      |> compact_map()

    _ = Log.info("evolution.signal.recorded", attrs, workspace_opts(opts))
    :ok
  end

  @spec recent_events(keyword()) :: [map()]
  def recent_events(opts \\ []) do
    Query.recent_events(Keyword.merge(workspace_opts(opts), limit: 50, tag_prefix: "evolution."))
  end

  @spec recent_signals(keyword()) :: [map()]
  def recent_signals(opts \\ []) do
    Query.recent_events(
      Keyword.merge(workspace_opts(opts), limit: 20, tag: "evolution.signal.recorded")
    )
  end

  @spec recent_candidates(keyword()) :: [map()]
  def recent_candidates(opts \\ []), do: Candidates.list(workspace_opts(opts))

  @spec candidate(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def candidate(candidate_id, opts \\ []), do: Candidates.get(candidate_id, workspace_opts(opts))

  @spec maybe_trigger_after_consolidation(keyword()) :: boolean()
  def maybe_trigger_after_consolidation(opts \\ []) do
    workspace_opts = workspace_opts(opts)
    counter_path = Path.join(Workspace.memory_dir(workspace_opts), @evolution_counter_file)

    current =
      case File.read(counter_path) do
        {:ok, content} ->
          case Integer.parse(String.trim(content)) do
            {n, _} -> n
            :error -> 0
          end

        {:error, _} ->
          0
      end

    new_count = current + 1
    File.write!(counter_path, to_string(new_count))

    if rem(new_count, @consolidations_per_evolution) == 0 do
      Log.info(
        "evolution.threshold_reached",
        %{"consolidation_count" => new_count, "threshold" => @consolidations_per_evolution},
        workspace_opts
      )

      Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
        run_evolution_cycle(Keyword.put(opts, :trigger, :post_consolidation))
      end)

      true
    else
      false
    end
  end

  defp run_cycle_with_evidence(evidence, :sleep, _opts) do
    candidates = low_cost_candidates(evidence, :sleep)

    {:skipped,
     %{
       "reason" => "budget mode sleep",
       "budget_mode" => "sleep",
       "candidate_count" => length(candidates),
       "pattern_count" => length(evidence["patterns"])
     }, candidates}
  end

  defp run_cycle_with_evidence(evidence, :low, _opts) do
    candidates = low_cost_candidates(evidence, :low)

    {:ok, completed_result(evidence, :low, candidates)}
  end

  defp run_cycle_with_evidence(evidence, budget_mode, opts)
       when budget_mode in [:normal, :deep] do
    profile = evidence["profile"] |> normalize_profile()

    case spend_budget(profile, opts) do
      {:ok, _ledger} ->
        with {:ok, report} <- run_reflection(evidence, profile, opts),
             {:ok, candidates} <- normalize_candidates(report, evidence) do
          {:ok, completed_result(evidence, budget_mode, candidates)}
        end

      {:error, :profile_not_allowed} ->
        attrs = %{
          "profile" => Atom.to_string(profile),
          "budget_mode" => Atom.to_string(budget_mode),
          "reason_type" => "profile_not_allowed",
          "error_summary" => "budget mode does not allow deep profile"
        }

        _ = Log.warning("evolution.budget.spend.failed", attrs, workspace_opts(opts))

        {:skipped,
         Map.merge(attrs, %{
           "reason" => "budget mode does not allow deep profile",
           "candidate_count" => 0
         }), []}

      {:error, :insufficient_budget} ->
        attrs = %{
          "profile" => Atom.to_string(profile),
          "budget_mode" => Atom.to_string(budget_mode),
          "reason_type" => "insufficient_budget",
          "error_summary" => "budget spend rejected"
        }

        _ = Log.warning("evolution.budget.spend.failed", attrs, workspace_opts(opts))
        {:skipped, Map.put(attrs, "reason", "insufficient budget"), []}

      {:error, reason} ->
        attrs = %{
          "profile" => Atom.to_string(profile),
          "budget_mode" => Atom.to_string(budget_mode),
          "reason_type" => reason_type(reason),
          "error_summary" => error_summary(reason)
        }

        _ = Log.warning("evolution.budget.spend.failed", attrs, workspace_opts(opts))
        {:skipped, Map.put(attrs, "reason", "budget spend failed"), []}
    end
  end

  defp spend_budget(:quick, opts), do: Budget.spend("evolution.quick", 4, opts)
  defp spend_budget(:routine, opts), do: Budget.spend("evolution.routine", 8, opts)

  defp spend_budget(:deep, opts) do
    case Budget.mode(Budget.current(opts)) do
      :deep -> Budget.spend("evolution.deep", 16, opts)
      _ -> {:error, :profile_not_allowed}
    end
  end

  defp run_reflection(evidence, profile, opts) do
    prompt = reflection_prompt(evidence, profile, opts)

    messages = [
      %{
        "role" => "system",
        "content" =>
          "You are an evolution analyst. Use the evidence pack and call evolution_report with candidate actions only."
      },
      %{"role" => "user", "content" => prompt}
    ]

    provider = Keyword.get(opts, :provider, :anthropic)

    llm_opts =
      [
        provider: provider,
        model: Keyword.get(opts, :model, "claude-sonnet-4-20250514"),
        api_key: Keyword.get(opts, :api_key),
        base_url: Keyword.get(opts, :base_url),
        tools: evolution_report_tool(),
        tool_choice: tool_choice_for(provider, "evolution_report")
      ]
      |> maybe_put_opt(:req_llm_stream_text_fun, Keyword.get(opts, :req_llm_stream_text_fun))

    llm_call_fun =
      Keyword.get(opts, :llm_call_fun, &Nex.Agent.Turn.Runner.call_llm_for_consolidation/2)

    case llm_call_fun.(messages, llm_opts) do
      {:ok, report} when is_map(report) -> {:ok, report}
      {:error, reason} -> {:error, {:llm_failed, reason}}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  defp reflection_prompt(evidence, profile, opts) do
    workspace_opts = workspace_opts(opts)
    soul = read_file(Workspace.root(workspace_opts), "SOUL.md")
    memory = read_file(Workspace.memory_dir(workspace_opts), "MEMORY.md")

    skills =
      Skills.list(workspace_opts)
      |> Enum.map(fn skill ->
        name = Map.get(skill, :name) || Map.get(skill, "name", "")
        description = Map.get(skill, :description) || Map.get(skill, "description", "")
        "- #{name}: #{description}"
      end)
      |> Enum.join("\n")

    """
    Analyze the ControlPlane evidence pack and propose owner-approved evolution candidates only.

    Rules:
    - Do not propose automatic deploys, patches, memory writes, skill writes, or SOUL changes.
    - Every candidate must cite evidence_ids drawn from the evidence pack observations.
    - Prefer concise, bounded candidates over broad redesigns.
    - Use `record_only` when evidence is weak.
    - `memory_candidate`, `skill_candidate`, `soul_candidate`, and `code_hint` are proposals only.

    Requested profile: #{Atom.to_string(profile)}

    ## Current Soul
    #{if soul == "", do: "(empty)", else: soul}

    ## Current Memory
    #{if memory == "", do: "(empty)", else: memory}

    ## Current Skills
    #{if skills == "", do: "(none)", else: skills}

    ## Evidence Pack
    #{Jason.encode!(evidence, pretty: true)}
    """
  end

  defp evolution_report_tool do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "evolution_report",
          "description" => "Return bounded candidate actions backed by ControlPlane evidence.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "observations" => %{
                "type" => "string",
                "description" => "Short summary of the evidence and repeated patterns."
              },
              "candidates" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "kind" => %{
                      "type" => "string",
                      "enum" => [
                        "record_only",
                        "reflection_candidate",
                        "memory_candidate",
                        "skill_candidate",
                        "soul_candidate",
                        "code_hint"
                      ]
                    },
                    "summary" => %{"type" => "string"},
                    "rationale" => %{"type" => "string"},
                    "evidence_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
                    "risk" => %{
                      "type" => "string",
                      "enum" => ["low", "medium", "high"]
                    }
                  },
                  "required" => ["kind", "summary", "rationale", "evidence_ids", "risk"]
                }
              }
            },
            "required" => ["observations", "candidates"]
          }
        }
      }
    ]
  end

  defp normalize_candidates(report, evidence) when is_map(report) do
    known_ids = MapSet.new(Enum.map(evidence["observations"], & &1["id"]))
    fallback_ids = evidence["observations"] |> Enum.take(3) |> Enum.map(& &1["id"])

    candidates =
      report
      |> Map.get("candidates", [])
      |> Enum.map(&normalize_candidate(&1, known_ids, fallback_ids))
      |> Enum.reject(&is_nil/1)

    {:ok, candidates}
  end

  defp normalize_candidates(_report, _evidence), do: {:ok, []}

  defp normalize_candidate(candidate, known_ids, fallback_ids) when is_map(candidate) do
    kind =
      candidate
      |> Map.get("kind", "record_only")
      |> to_string()

    if kind in [
         "record_only",
         "reflection_candidate",
         "memory_candidate",
         "skill_candidate",
         "soul_candidate",
         "code_hint"
       ] do
      evidence_ids =
        candidate
        |> Map.get("evidence_ids", [])
        |> Enum.map(&to_string/1)
        |> Enum.filter(&MapSet.member?(known_ids, &1))
        |> case do
          [] -> fallback_ids
          ids -> Enum.uniq(ids)
        end

      %{
        "id" => Store.new_id(),
        "kind" => kind,
        "summary" => candidate |> Map.get("summary", "") |> bounded_string(280),
        "rationale" => candidate |> Map.get("rationale", "") |> bounded_string(800),
        "evidence_ids" => evidence_ids,
        "risk" => candidate |> Map.get("risk", "low") |> normalize_risk(),
        "requires_owner_approval" => true,
        "created_at" => Store.timestamp()
      }
    end
  end

  defp normalize_candidate(_, _known_ids, _fallback_ids), do: nil

  defp low_cost_candidates(evidence, :sleep) do
    case List.first(evidence["patterns"]) do
      nil ->
        []

      pattern ->
        [
          %{
            "id" => Store.new_id(),
            "kind" => "record_only",
            "summary" => "Recorded repeated runtime evidence under sleep budget",
            "rationale" =>
              "Budget mode is sleep, so the cycle only recorded the strongest repeated pattern: #{pattern["tag"]}.",
            "evidence_ids" => pattern["sample_ids"],
            "risk" => "low",
            "requires_owner_approval" => true,
            "created_at" => Store.timestamp()
          }
        ]
    end
  end

  defp low_cost_candidates(evidence, :low) do
    case List.first(evidence["patterns"]) do
      nil ->
        []

      pattern ->
        [
          %{
            "id" => Store.new_id(),
            "kind" => "reflection_candidate",
            "summary" => "Review repeated pattern #{pattern["tag"]}",
            "rationale" =>
              "Low budget mode blocked LLM reflection, but repeated #{pattern["severity"]} observations suggest manual review is warranted.",
            "evidence_ids" => pattern["sample_ids"],
            "risk" => risk_for_severity(pattern["severity"]),
            "requires_owner_approval" => true,
            "created_at" => Store.timestamp()
          }
        ]
    end
  end

  defp completed_result(evidence, budget_mode, candidates) do
    %{
      status: :completed,
      trigger: evidence["trigger"] |> normalize_trigger(),
      profile: evidence["profile"] |> normalize_profile(),
      budget_mode: budget_mode,
      evidence_count: length(evidence["observations"]),
      pattern_count: length(evidence["patterns"]),
      candidate_count: length(candidates),
      candidates: candidates
    }
  end

  defp skipped_result(trigger, profile, budget_mode, evidence, candidates) do
    %{
      status: :skipped,
      trigger: trigger,
      profile: profile,
      budget_mode: budget_mode,
      evidence_count: length(evidence["observations"]),
      pattern_count: length(evidence["patterns"]),
      candidate_count: length(candidates),
      candidates: candidates
    }
  end

  defp emit_candidate_observations(candidates, evidence, opts) do
    Enum.each(candidates, fn candidate ->
      emit_superseded_candidates(candidate, opts)

      attrs =
        candidate
        |> Map.take([
          "id",
          "kind",
          "summary",
          "rationale",
          "evidence_ids",
          "risk",
          "requires_owner_approval",
          "created_at"
        ])
        |> Map.put("trigger", evidence["trigger"])
        |> Map.put("profile", evidence["profile"])
        |> Map.put("budget_mode", evidence["budget"]["mode"])

      _ = Log.info("evolution.candidate.proposed", attrs, opts)
    end)
  end

  defp emit_superseded_candidates(candidate, opts) do
    Candidates.list(opts)
    |> Enum.filter(fn existing ->
      existing["status"] == "pending" and existing["candidate_id"] != candidate["id"] and
        existing["kind"] == candidate["kind"] and existing["summary"] == candidate["summary"]
    end)
    |> Enum.each(fn existing ->
      _ =
        Log.info(
          "evolution.candidate.superseded",
          %{
            "candidate_id" => existing["candidate_id"],
            "superseded_by" => candidate["id"],
            "kind" => existing["kind"],
            "summary" => existing["summary"]
          },
          opts
        )
    end)
  end

  defp log_cycle(level, tag, evidence, attrs, opts) do
    payload = Map.merge(base_cycle_attrs(evidence), stringify_keys(attrs))

    _ =
      case level do
        :warning -> Log.warning(tag, payload, opts)
        :error -> Log.error(tag, payload, opts)
        _ -> Log.info(tag, payload, opts)
      end
  end

  defp base_cycle_attrs(evidence) do
    %{
      "trigger" => evidence["trigger"],
      "profile" => evidence["profile"],
      "budget_mode" => get_in(evidence, ["budget", "mode"]),
      "window" => evidence["window"],
      "evidence_count" => length(evidence["observations"]),
      "pattern_count" => length(evidence["patterns"])
    }
  end

  defp workspace_opts(opts) do
    case Keyword.get(opts, :workspace) do
      nil -> []
      workspace -> [workspace: workspace]
    end
  end

  defp resolve_runtime_llm_opts(opts) do
    config = Config.load(config_opts(opts))
    model_runtime = Config.default_model_runtime(config)

    [
      provider: Keyword.get(opts, :provider) || (model_runtime && model_runtime.provider),
      model: Keyword.get(opts, :model) || (model_runtime && model_runtime.model_id),
      api_key: Keyword.get(opts, :api_key) || (model_runtime && model_runtime.api_key),
      base_url: Keyword.get(opts, :base_url) || (model_runtime && model_runtime.base_url),
      provider_options:
        Keyword.get(opts, :provider_options) || (model_runtime && model_runtime.provider_options)
    ]
  end

  defp read_file(dir, filename) do
    case File.read(Path.join(dir, filename)) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp normalize_trigger(trigger)
       when trigger in [:manual, :post_consolidation, :scheduled_daily, :scheduled_weekly],
       do: trigger

  defp normalize_trigger(trigger) when is_binary(trigger) do
    case trigger do
      "manual" -> :manual
      "post_consolidation" -> :post_consolidation
      "scheduled_daily" -> :scheduled_daily
      "scheduled_weekly" -> :scheduled_weekly
      _ -> :manual
    end
  end

  defp normalize_trigger(_), do: :manual

  defp normalize_profile(profile) when profile in [:quick, :routine, :deep], do: profile
  defp normalize_profile("quick"), do: :quick
  defp normalize_profile("routine"), do: :routine
  defp normalize_profile("deep"), do: :deep
  defp normalize_profile(_), do: :routine

  defp normalize_budget_mode(mode) when mode in [:sleep, :low, :normal, :deep], do: mode
  defp normalize_budget_mode("sleep"), do: :sleep
  defp normalize_budget_mode("low"), do: :low
  defp normalize_budget_mode("normal"), do: :normal
  defp normalize_budget_mode("deep"), do: :deep
  defp normalize_budget_mode(_), do: :sleep

  defp profile_for_trigger(:manual), do: :routine
  defp profile_for_trigger(:post_consolidation), do: :quick
  defp profile_for_trigger(:scheduled_daily), do: :routine
  defp profile_for_trigger(:scheduled_weekly), do: :deep

  defp tool_choice_for(_provider, name), do: %{type: "tool", name: name}
  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp config_opts(opts) do
    case Keyword.get(opts, :config_path) do
      nil -> []
      config_path -> [config_path: config_path]
    end
  end

  defp bounded_string(value, limit) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, limit)
  end

  defp bounded_string(value, limit), do: value |> to_string() |> bounded_string(limit)

  defp normalize_risk(risk) when risk in ["low", "medium", "high"], do: risk
  defp normalize_risk(:low), do: "low"
  defp normalize_risk(:medium), do: "medium"
  defp normalize_risk(:high), do: "high"
  defp normalize_risk(_), do: "low"

  defp risk_for_severity("critical"), do: "high"
  defp risk_for_severity("error"), do: "medium"
  defp risk_for_severity(_), do: "low"

  defp compact_map(map) do
    map
    |> stringify_keys()
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_keys(other), do: other

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp reason_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_type(reason) when is_binary(reason), do: String.slice(reason, 0, 120)
  defp reason_type({reason, _detail}), do: reason_type(reason)
  defp reason_type(reason), do: inspect(reason, limit: 20, printable_limit: 120)

  defp error_summary(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 300)
    |> String.slice(0, 300)
  end
end
