defmodule Nex.Agent.Capability.Tool.Core.PermissionRuleInspector do
  @moduledoc false

  alias Nex.Agent.Capability.Tool.Core.AddPermissionRule

  alias Nex.Agent.Sandbox.PermissionRule.{
    Decision,
    EnrichedPermissionEvent,
    PermissionRequirement,
    RequirementDecision,
    Rule
  }

  @spec candidate_rules(map(), map()) :: {:ok, [Rule.t()], [String.t()]} | {:error, String.t()}
  def candidate_rules(args, ctx) do
    args
    |> candidate_rule_inputs()
    |> Enum.reduce_while({:ok, [], []}, fn candidate, {:ok, rules, subjects} ->
      case build_candidate_rule(candidate, ctx) do
        {:ok, rule, subject} -> {:cont, {:ok, [rule | rules], [subject | subjects]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rules, subjects} -> {:ok, Enum.reverse(rules), Enum.reverse(subjects)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec raw_event(map(), map()) :: map()
  def raw_event(%{} = event, ctx) do
    event = stringify_keys(event)
    params = event |> Map.get("params", %{}) |> stringify_keys()

    params =
      params
      |> maybe_put("command", event["command"])
      |> maybe_put("path", event["path"])
      |> maybe_put("operation", event["operation"])
      |> maybe_put("sandbox_permissions", event["sandbox_permissions"])

    %{
      tool_name: event["tool_name"] || infer_tool_name(params),
      params: params,
      channel: event["channel"] || text_value(ctx, :channel),
      chat_id: event["chat_id"] || text_value(ctx, :chat_id),
      workspace: event["workspace"] || text_value(ctx, :workspace),
      cwd: event["cwd"] || text_value(ctx, :cwd) || text_value(ctx, :workspace),
      requested_execution: event["requested_execution"],
      metadata: stringify_keys(event["metadata"] || %{})
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec result(Decision.t(), keyword()) :: map()
  def result(%Decision{} = decision, opts \\ []) do
    subjects = Keyword.get(opts, :candidate_rule_subjects, [])
    source = Keyword.get(opts, :source, "candidate_rules")
    rule_count = Keyword.get(opts, :rule_count)

    %{
      action: Atom.to_string(decision.action),
      allowed?: decision.action == :allow,
      source: source,
      rule_count: rule_count,
      reason: decision.reason,
      hint: hint(decision, source),
      candidate_rule_subjects: subjects,
      event: event_summary(decision.enriched_event),
      requirements: Enum.map(decision.requirement_decisions, &requirement_decision_summary/1),
      uncovered_requirements:
        decision.requirement_decisions
        |> Enum.reject(&(&1.action == :allow))
        |> Enum.map(&requirement_decision_summary/1)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec text_value(map(), atom()) :: String.t() | nil
  def text_value(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  def text_value(_map, _key), do: nil

  @spec permission_context(map(), map()) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  def permission_context(event_or_args, ctx) do
    workspace =
      text_value(event_or_args, :workspace) ||
        text_value(ctx, :workspace) ||
        text_value(ctx, :cwd)

    session_key =
      text_value(ctx, :session_key) ||
        case {text_value(event_or_args, :channel), text_value(event_or_args, :chat_id)} do
          {channel, chat_id} when is_binary(channel) and is_binary(chat_id) ->
            "#{channel}:#{chat_id}"

          _ ->
            case {text_value(ctx, :channel), text_value(ctx, :chat_id)} do
              {channel, chat_id} when is_binary(channel) and is_binary(chat_id) ->
                "#{channel}:#{chat_id}"

              _ ->
                nil
            end
        end

    cond do
      is_nil(workspace) ->
        {:error, "permission tools require workspace context"}

      is_nil(session_key) ->
        {:error, "permission tools require session_key or channel/chat_id context"}

      true ->
        {:ok, workspace, session_key}
    end
  end

  @spec rule_summary(map(), map()) :: map()
  def rule_summary(%{rule: %Rule{} = rule, rule_ref: rule_ref, persistence: persistence}, ctx) do
    predicates = rule.predicates

    %{
      rule_ref: rule_ref,
      persistence: Atom.to_string(persistence),
      removable?: removable_rule?(rule),
      effect: Atom.to_string(rule.effect),
      level: rule.level,
      scope: Atom.to_string(rule.scope),
      resource: resource_summary(predicates),
      operations: operation_summary(predicates),
      match: match_summary(predicates),
      context: context_summary(predicates),
      applies_to_current_context?: rule_applies_to_context?(rule, ctx),
      reason: blank_to_nil(rule.reason),
      source: Atom.to_string(rule.source),
      created_at: datetime_to_string(rule.created_at),
      expires_at: datetime_to_string(rule.expires_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def rule_summary(%{} = entry, ctx) do
    entry
    |> Map.update!(:rule, &Rule.new/1)
    |> rule_summary(ctx)
  end

  @spec rule_applies_to_context?(Rule.t(), map()) :: boolean()
  def rule_applies_to_context?(%Rule{} = rule, ctx) do
    channel = text_value(ctx, :channel)
    chat_id = text_value(ctx, :chat_id)

    Enum.all?(rule.predicates, fn
      {:eq, :channel, expected} -> is_nil(channel) or expected == channel
      {:eq, :chat_id, expected} -> is_nil(chat_id) or expected == chat_id
      _predicate -> true
    end)
  end

  defp candidate_rule_inputs(%{"candidate_rules" => rules}) when is_list(rules), do: rules
  defp candidate_rule_inputs(%{"candidate_rule" => rule}) when is_map(rule), do: [rule]
  defp candidate_rule_inputs(%{"rule" => rule}) when is_map(rule), do: [rule]
  defp candidate_rule_inputs(%{"resource" => _resource} = args), do: [args]
  defp candidate_rule_inputs(_args), do: []

  defp build_candidate_rule(%{} = candidate, ctx) do
    candidate = stringify_keys(candidate)

    cond do
      is_list(candidate["predicates"]) ->
        rule = Rule.new(candidate)
        {:ok, rule, candidate["id"] || "raw rule candidate"}

      is_binary(candidate["resource"]) ->
        candidate = Map.put_new(candidate, "reason", "Permission rule candidate")

        case AddPermissionRule.build_rule(candidate["resource"], candidate, ctx) do
          {:ok, %Rule{} = rule, subject, _kind, _operation} -> {:ok, rule, subject}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, "candidate_rule requires resource or predicates"}
    end
  end

  defp event_summary(%EnrichedPermissionEvent{} = event) do
    %{
      tool_name: event.raw.tool_name,
      command_program: event.command_program,
      command_tokens: event.command_tokens,
      requested_execution: Atom.to_string(event.requested_execution),
      risk_class: Atom.to_string(event.risk_class),
      inferred_network_hosts: event.inferred_network_hosts,
      shell_features: event.shell_features |> MapSet.to_list() |> Enum.map(&Atom.to_string/1)
    }
  end

  defp event_summary(_event), do: %{}

  defp removable_rule?(%Rule{effect: :allow, level: 0, source: :owner_grant}), do: true
  defp removable_rule?(_rule), do: false

  defp resource_summary(predicates) do
    predicates
    |> Enum.find_value(fn
      {:resource_eq, resource} -> Atom.to_string(resource)
      _predicate -> nil
    end)
  end

  defp operation_summary(predicates) do
    predicates
    |> Enum.find_value([], fn
      {:operation_in, operations} -> Enum.map(operations, &Atom.to_string/1)
      _predicate -> nil
    end)
  end

  defp match_summary(predicates) do
    [
      path_match_summary(predicates),
      command_match_summary(predicates),
      execution_match_summary(predicates),
      risk_match_summary(predicates)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "all matching requirements"
      parts -> Enum.join(parts, "; ")
    end
  end

  defp path_match_summary(predicates) do
    Enum.find_value(predicates, fn
      {:path_under, path} -> "path under #{path}"
      {:path_eq, path} -> "path #{path}"
      _predicate -> nil
    end)
  end

  defp command_match_summary(predicates) do
    Enum.find_value(predicates, fn
      {:exact, :command_tokens, tokens} -> "exact command `#{Enum.join(tokens, " ")}`"
      {:prefix, :command_tokens, tokens} -> "command prefix `#{Enum.join(tokens, " ")} ...`"
      _predicate -> nil
    end)
  end

  defp execution_match_summary(predicates) do
    Enum.find_value(predicates, fn
      {:eq, :requested_execution, execution} -> "#{execution} execution"
      _predicate -> nil
    end)
  end

  defp risk_match_summary(predicates) do
    Enum.find_value(predicates, fn
      {:risk_in, risks} -> "risk in #{Enum.map_join(risks, "/", &Atom.to_string/1)}"
      _predicate -> nil
    end)
  end

  defp context_summary(predicates) do
    channel =
      Enum.find_value(predicates, fn
        {:eq, :channel, value} -> value
        _predicate -> nil
      end)

    chat_id =
      Enum.find_value(predicates, fn
        {:eq, :chat_id, value} -> value
        _predicate -> nil
      end)

    cond do
      is_binary(channel) and is_binary(chat_id) -> "thread #{channel}:#{chat_id}"
      is_binary(channel) -> "channel #{channel}"
      true -> "workspace"
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp requirement_decision_summary(%RequirementDecision{} = decision) do
    requirement = decision.requirement

    %{
      resource: Atom.to_string(requirement.resource),
      operation: Atom.to_string(requirement.operation),
      target: requirement.target,
      action: Atom.to_string(decision.action),
      winning_rule_id: decision.winning_rule_id,
      matched_rule_ids: decision.matched_rule_ids,
      reason: decision.reason
    }
  end

  defp hint(%Decision{action: :allow}, _source) do
    "Every derived requirement for this event is allowed."
  end

  defp hint(%Decision{} = decision, source) do
    uncovered =
      decision.requirement_decisions
      |> Enum.reject(&(&1.action == :allow))
      |> Enum.map(& &1.requirement)

    cond do
      Enum.any?(uncovered, &command_execute?/1) ->
        "This event still needs command:execute coverage. A path rule only covers path requirements; bash also derives a command execution requirement."

      Enum.any?(uncovered, &path_requirement?/1) and source == "current_rules" ->
        "Current approved rules do not cover at least one path requirement for this event."

      Enum.any?(uncovered, &path_requirement?/1) ->
        "The supplied candidate rules do not cover at least one path requirement for this event."

      true ->
        "At least one derived requirement is not allowed."
    end
  end

  defp command_execute?(%PermissionRequirement{resource: :command, operation: :execute}), do: true
  defp command_execute?(_requirement), do: false

  defp path_requirement?(%PermissionRequirement{resource: :path}), do: true
  defp path_requirement?(_requirement), do: false

  defp infer_tool_name(%{"command" => command}) when is_binary(command), do: "bash"
  defp infer_tool_name(%{"path" => path}) when is_binary(path), do: "filesystem"
  defp infer_tool_name(_params), do: "unknown"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put_new(map, key, value)

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_value), do: %{}
end
