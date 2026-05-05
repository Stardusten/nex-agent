defmodule Nex.Agent.Sandbox.PermissionRule do
  @moduledoc """
  Data-first permission rule engine.

  Callers provide raw tool events. This module owns enrichment, command
  tokenization, path normalization, requirement extraction, predicate matching,
  specificity ranking, and rule proposals.
  """

  alias __MODULE__.{
    ActorRef,
    Decision,
    EnrichedPermissionEvent,
    GrantProposal,
    PermissionRequirement,
    RawToolEvent,
    RequirementDecision,
    Rule
  }

  @read_operations ~w(read list search stat stream)a
  @path_operations @read_operations ++ ~w(write remove mkdir)a
  @known_operations @path_operations ++ ~w(call execute connect)a
  defmodule Util do
    @moduledoc false

    @known_effects ~w(allow ask deny)a
    @known_scopes ~w(thread channel workspace global)a
    @known_sources ~w(system owner_grant workspace_config runtime)a
    @known_actor_kinds ~w(user system owner_run subagent)a
    @known_execution ~w(sandboxed elevated)a
    @known_rule_atoms @known_effects ++
                        @known_scopes ++
                        @known_sources ++
                        @known_actor_kinds ++
                        @known_execution ++
                        ~w(tool command path network process code read write list search remove mkdir stat stream call execute connect filesystem network_fetch shell_escape interpreter_code command_substitution process_substitution encoded_shell unknown)a

    def normalize_attrs(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalize_attrs()

    def normalize_attrs(attrs) when is_map(attrs) do
      Map.new(attrs, fn {key, value} ->
        key =
          cond do
            is_atom(key) -> key
            is_binary(key) -> safe_existing_atom(key)
            true -> key
          end

        {key, value}
      end)
    end

    def normalize_map(%{} = map), do: map
    def normalize_map(_map), do: %{}

    def normalize_params(%{} = params) do
      Map.new(params, fn {key, value} -> {to_string(key), value} end)
    end

    def normalize_params(_params), do: %{}

    def normalize_actor_kind(value, default),
      do: normalize_one_of(value, @known_actor_kinds, default)

    def normalize_execution(value, default),
      do: normalize_one_of(value, @known_execution, default)

    def normalize_effect(value, default), do: normalize_one_of(value, @known_effects, default)
    def normalize_scope(value, default), do: normalize_one_of(value, @known_scopes, default)
    def normalize_source(value, default), do: normalize_one_of(value, @known_sources, default)

    def normalize_level(value) when is_integer(value) and value >= 0, do: value

    def normalize_level(value) when is_binary(value) do
      case Integer.parse(value) do
        {level, ""} when level >= 0 -> level
        _ -> 0
      end
    end

    def normalize_level(_value), do: 0

    def optional_string(value), do: string(value, nil)

    def optional_path(value) do
      case optional_string(value) do
        nil -> nil
        path -> Path.expand(path)
      end
    end

    def string(value, default) when is_binary(value) do
      value = String.trim(value)
      if value == "", do: default, else: value
    end

    def string(value, _default) when is_atom(value) and not is_nil(value),
      do: Atom.to_string(value)

    def string(value, _default) when is_integer(value), do: Integer.to_string(value)
    def string(_value, default), do: default

    def normalize_datetime(%DateTime{} = datetime), do: datetime

    def normalize_datetime(value) when is_binary(value) do
      case DateTime.from_iso8601(value) do
        {:ok, datetime, _offset} -> datetime
        _ -> nil
      end
    end

    def normalize_datetime(_value), do: nil

    def known_atom(value), do: normalize_one_of(value, @known_rule_atoms, nil)

    def normalize_one_of(value, allowed, default) when is_atom(value) do
      if value in allowed, do: value, else: default
    end

    def normalize_one_of(value, allowed, default) when is_binary(value) do
      normalized =
        value
        |> String.trim()
        |> String.downcase()
        |> String.replace("-", "_")

      Enum.find(allowed, default, &(Atom.to_string(&1) == normalized))
    end

    def normalize_one_of(_value, _allowed, default), do: default

    def normalize_atoms(values) when is_list(values) do
      values
      |> Enum.map(&known_atom/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end

    def normalize_atoms(value), do: normalize_atoms([value])

    def normalize_tokens(tokens) when is_list(tokens), do: Enum.map(tokens, &to_string/1)
    def normalize_tokens(token) when is_binary(token), do: [token]
    def normalize_tokens(_tokens), do: []

    defp safe_existing_atom(value) when is_binary(value) do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> value
    end
  end

  defmodule ActorRef do
    @moduledoc "Principal that triggered or authorized a permission event."

    @type kind :: :user | :system | :owner_run | :subagent

    @type t :: %__MODULE__{
            kind: kind(),
            channel: String.t() | nil,
            id: String.t() | nil,
            display: String.t() | nil
          }

    defstruct kind: :user,
              channel: nil,
              id: nil,
              display: nil

    @spec new(map() | keyword() | t() | nil) :: t() | nil
    def new(nil), do: nil
    def new(%__MODULE__{} = actor), do: actor

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      attrs = Util.normalize_attrs(attrs)

      %__MODULE__{
        kind: Util.normalize_actor_kind(Map.get(attrs, :kind), :user),
        channel: Util.optional_string(Map.get(attrs, :channel)),
        id: Util.optional_string(Map.get(attrs, :id)),
        display: Util.optional_string(Map.get(attrs, :display))
      }
    end
  end

  defmodule RawToolEvent do
    @moduledoc "Raw permission event supplied by tool callers."

    @type execution :: :sandboxed | :elevated

    @type t :: %__MODULE__{
            tool_name: String.t(),
            params: map(),
            channel: String.t() | nil,
            chat_id: String.t() | nil,
            workspace: String.t() | nil,
            cwd: String.t() | nil,
            requested_execution: execution(),
            actor: ActorRef.t() | nil,
            metadata: map()
          }

    defstruct tool_name: "",
              params: %{},
              channel: nil,
              chat_id: nil,
              workspace: nil,
              cwd: nil,
              requested_execution: :sandboxed,
              actor: nil,
              metadata: %{}

    @spec new(map() | keyword() | t()) :: t()
    def new(%__MODULE__{} = event), do: event

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      attrs = Util.normalize_attrs(attrs)
      metadata = Util.normalize_map(Map.get(attrs, :metadata))

      params =
        attrs
        |> Map.get(:params)
        |> Util.normalize_params()
        |> maybe_put_param("command", Map.get(attrs, :command))
        |> maybe_put_param("path", Map.get(attrs, :path) || Map.get(attrs, :subject))
        |> maybe_put_param("operation", Map.get(attrs, :operation))

      tool_name =
        Map.get(attrs, :tool_name)
        |> Util.optional_string()
        |> case do
          nil -> infer_tool_name(attrs, params)
          value -> value
        end

      %__MODULE__{
        tool_name: tool_name,
        params: params,
        channel: Util.optional_string(Map.get(attrs, :channel)),
        chat_id: Util.optional_string(Map.get(attrs, :chat_id)),
        workspace: Util.optional_path(Map.get(attrs, :workspace)),
        cwd: Util.optional_path(Map.get(attrs, :cwd)),
        requested_execution:
          Util.normalize_execution(
            Map.get(attrs, :requested_execution) ||
              Map.get(params, "requested_execution") ||
              execution_from_sandbox_permission(Map.get(params, "sandbox_permissions")) ||
              execution_from_sandbox_permission(Map.get(metadata, "sandbox_permissions")) ||
              execution_from_sandbox_permission(Map.get(metadata, :sandbox_permissions)),
            :sandboxed
          ),
        actor: ActorRef.new(Map.get(attrs, :actor)),
        metadata: metadata
      }
    end

    defp maybe_put_param(params, _key, nil), do: params
    defp maybe_put_param(params, _key, ""), do: params
    defp maybe_put_param(params, key, value), do: Map.put_new(params, key, value)

    defp infer_tool_name(_attrs, %{"command" => command}) when is_binary(command), do: "bash"
    defp infer_tool_name(_attrs, %{"path" => path}) when is_binary(path), do: "filesystem"
    defp infer_tool_name(_attrs, _params), do: "unknown"

    defp execution_from_sandbox_permission("require_escalated"), do: :elevated
    defp execution_from_sandbox_permission(:require_escalated), do: :elevated
    defp execution_from_sandbox_permission(_value), do: nil
  end

  defmodule PermissionRequirement do
    @moduledoc "One semantic effect that must be covered by permission rules."

    @type t :: %__MODULE__{
            id: String.t(),
            resource: atom(),
            operation: atom(),
            target: String.t() | nil,
            tags: MapSet.t(atom()),
            attrs: map()
          }

    defstruct id: "",
              resource: :tool,
              operation: :call,
              target: nil,
              tags: MapSet.new(),
              attrs: %{}
  end

  defmodule EnrichedPermissionEvent do
    @moduledoc "Rule-engine derived event context."

    @type risk_class ::
            :read
            | :write
            | :network_fetch
            | :shell_escape
            | :interpreter_code
            | :command_substitution
            | :process_substitution
            | :encoded_shell
            | :unknown

    @type t :: %__MODULE__{
            raw: RawToolEvent.t(),
            tags: MapSet.t(atom()),
            requirements: [PermissionRequirement.t()],
            command_tokens: [String.t()],
            command_program: String.t() | nil,
            command_prefixes: [[String.t()]],
            shell_features: MapSet.t(atom()),
            requested_execution: RawToolEvent.execution(),
            inferred_network_hosts: [String.t()],
            risk_class: risk_class(),
            risk_hints: [String.t()]
          }

    defstruct raw: %RawToolEvent{},
              tags: MapSet.new(),
              requirements: [],
              command_tokens: [],
              command_program: nil,
              command_prefixes: [],
              shell_features: MapSet.new(),
              requested_execution: :sandboxed,
              inferred_network_hosts: [],
              risk_class: :unknown,
              risk_hints: []
  end

  defmodule Rule do
    @moduledoc "Structured permission rule."

    @type effect :: :allow | :ask | :deny
    @type scope :: :thread | :channel | :workspace | :global
    @type source :: :system | :owner_grant | :workspace_config | :runtime
    @type predicate ::
            {:eq, atom(), term()}
            | {:in, atom(), [term()]}
            | {:contains, atom(), term()}
            | {:tag_in, [atom()]}
            | {:resource_eq, atom()}
            | {:operation_in, [atom()]}
            | {:path_eq, String.t()}
            | {:path_under, String.t()}
            | {:exact, :command_tokens, [String.t()]}
            | {:prefix, :command_tokens, [String.t()]}
            | {:risk_in, [atom()]}
            | {:scope_eq, scope()}

    @type t :: %__MODULE__{
            id: String.t(),
            level: non_neg_integer(),
            effect: effect(),
            scope: scope(),
            predicates: [predicate()],
            reason: String.t(),
            created_by: ActorRef.t() | nil,
            created_at: DateTime.t() | nil,
            expires_at: DateTime.t() | nil,
            source: source()
          }

    defstruct id: "",
              level: 0,
              effect: :ask,
              scope: :global,
              predicates: [],
              reason: "",
              created_by: nil,
              created_at: nil,
              expires_at: nil,
              source: :runtime

    @spec new(map() | keyword() | t()) :: t()
    def new(%__MODULE__{} = rule), do: rule

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      attrs = Util.normalize_attrs(attrs)

      %__MODULE__{
        id: Util.string(Map.get(attrs, :id), ""),
        level: Util.normalize_level(Map.get(attrs, :level)),
        effect: Util.normalize_effect(Map.get(attrs, :effect), :ask),
        scope: Util.normalize_scope(Map.get(attrs, :scope), :global),
        predicates: normalize_predicates(Map.get(attrs, :predicates)),
        reason: Util.string(Map.get(attrs, :reason), ""),
        created_by: ActorRef.new(Map.get(attrs, :created_by)),
        created_at: Util.normalize_datetime(Map.get(attrs, :created_at)),
        expires_at: Util.normalize_datetime(Map.get(attrs, :expires_at)),
        source: Util.normalize_source(Map.get(attrs, :source), :runtime)
      }
    end

    defp normalize_predicates(predicates) when is_list(predicates) do
      predicates
      |> Enum.map(&normalize_predicate/1)
      |> Enum.reject(&is_nil/1)
    end

    defp normalize_predicates(_predicates), do: []

    defp normalize_predicate({:eq, field, value}) when is_atom(field),
      do: {:eq, field, normalize_value(field, value)}

    defp normalize_predicate({:in, field, values}) when is_atom(field) and is_list(values),
      do: {:in, field, Enum.map(values, &normalize_value(field, &1))}

    defp normalize_predicate({:contains, field, value}) when is_atom(field),
      do: {:contains, field, normalize_value(field, value)}

    defp normalize_predicate({:tag_in, tags}), do: {:tag_in, Util.normalize_atoms(tags)}

    defp normalize_predicate({:resource_eq, resource}),
      do: {:resource_eq, Util.known_atom(resource)}

    defp normalize_predicate({:operation_in, operations}),
      do: {:operation_in, Util.normalize_atoms(operations)}

    defp normalize_predicate({:path_eq, path}), do: {:path_eq, normalize_path(path)}
    defp normalize_predicate({:path_under, path}), do: {:path_under, normalize_path(path)}

    defp normalize_predicate({:exact, :command_tokens, tokens}),
      do: {:exact, :command_tokens, Util.normalize_tokens(tokens)}

    defp normalize_predicate({:prefix, :command_tokens, tokens}),
      do: {:prefix, :command_tokens, Util.normalize_tokens(tokens)}

    defp normalize_predicate({:risk_in, risks}), do: {:risk_in, Util.normalize_atoms(risks)}

    defp normalize_predicate({:scope_eq, scope}),
      do: {:scope_eq, Util.normalize_scope(scope, nil)}

    defp normalize_predicate(%{} = predicate) do
      predicate = Util.normalize_attrs(predicate)

      case string_value(predicate, :op) do
        "eq" ->
          field = field_atom(value(predicate, :field))
          {:eq, field, normalize_value(field, value(predicate, :value))}

        "in" ->
          field = field_atom(value(predicate, :field))
          {:in, field, Enum.map(value(predicate, :values) || [], &normalize_value(field, &1))}

        "contains" ->
          field = field_atom(value(predicate, :field))
          {:contains, field, normalize_value(field, value(predicate, :value))}

        "tag_in" ->
          {:tag_in,
           Util.normalize_atoms(value(predicate, :tags) || value(predicate, :values) || [])}

        "resource_eq" ->
          {:resource_eq, Util.known_atom(value(predicate, :resource) || value(predicate, :value))}

        "operation_in" ->
          {:operation_in,
           Util.normalize_atoms(value(predicate, :operations) || value(predicate, :values) || [])}

        "path_eq" ->
          {:path_eq, normalize_path(value(predicate, :path) || value(predicate, :value))}

        "path_under" ->
          {:path_under,
           normalize_path(
             value(predicate, :path) || value(predicate, :root) || value(predicate, :value)
           )}

        "exact" ->
          {:exact, :command_tokens, Util.normalize_tokens(value(predicate, :tokens))}

        "prefix" ->
          {:prefix, :command_tokens, Util.normalize_tokens(value(predicate, :tokens))}

        "risk_in" ->
          {:risk_in, Util.normalize_atoms(value(predicate, :risks) || [])}

        "scope_eq" ->
          {:scope_eq, Util.normalize_scope(value(predicate, :scope), nil)}

        _other ->
          nil
      end
    end

    defp normalize_predicate(_predicate), do: nil

    defp normalize_path(path) do
      case Util.optional_string(path) do
        nil -> nil
        value -> Path.expand(value)
      end
    end

    defp normalize_value(field, value)
         when field in [:resource, :operation, :risk_class, :requested_execution],
         do: Util.known_atom(value)

    defp normalize_value(_field, value), do: value

    defp field_atom(value) when is_atom(value), do: value

    defp field_atom(value) when is_binary(value) do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> nil
    end

    defp field_atom(_value), do: nil

    defp string_value(map, key) do
      case value(map, key) do
        value when is_binary(value) -> value
        value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
        _value -> nil
      end
    end

    defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defmodule RequirementDecision do
    @moduledoc "Rule decision for a single permission requirement."

    @type t :: %__MODULE__{
            requirement: PermissionRequirement.t(),
            action: :allow | :ask | :deny,
            matched_rule_ids: [String.t()],
            winning_rule_id: String.t() | nil,
            reason: String.t()
          }

    defstruct requirement: %PermissionRequirement{},
              action: :ask,
              matched_rule_ids: [],
              winning_rule_id: nil,
              reason: "No permission rule matched."
  end

  defmodule GrantProposal do
    @moduledoc "Concrete rule proposal that approval UI can present."

    @type t :: %__MODULE__{
            id: String.t(),
            label: String.t(),
            rule: Rule.t() | nil,
            risk_summary: String.t()
          }

    defstruct id: "",
              label: "",
              rule: nil,
              risk_summary: ""
  end

  defmodule Decision do
    @moduledoc "Result of permission rule evaluation."

    @type action :: :allow | :ask | :deny
    @type severity :: :info | :warning | :danger

    @type t :: %__MODULE__{
            action: action(),
            matched_rule_ids: [String.t()],
            winning_rule_id: String.t() | nil,
            reason: String.t(),
            severity: severity(),
            suggested_grants: [GrantProposal.t()],
            enriched_event: EnrichedPermissionEvent.t() | nil,
            requirement_decisions: [RequirementDecision.t()]
          }

    defstruct action: :ask,
              matched_rule_ids: [],
              winning_rule_id: nil,
              reason: "No permission rule matched.",
              severity: :warning,
              suggested_grants: [],
              enriched_event: nil,
              requirement_decisions: []
  end

  @type rule_runtime :: %{optional(:rules) => [Rule.t() | map() | keyword()]}

  @spec decide(RawToolEvent.t() | map() | keyword(), rule_runtime() | [Rule.t()]) :: Decision.t()
  def decide(raw_event, runtime_or_rules \\ []) do
    event = enrich(raw_event)
    rules = rules_from_runtime(runtime_or_rules) |> Enum.map(&Rule.new/1)

    requirement_decisions =
      event.requirements
      |> Enum.map(&decide_requirement(event, &1, rules))

    fold_decision(event, requirement_decisions)
  end

  @spec enrich(RawToolEvent.t() | map() | keyword()) :: EnrichedPermissionEvent.t()
  def enrich(raw_event) do
    raw = RawToolEvent.new(raw_event)
    command = command_from_raw(raw)
    tokens = tokenize(command || "")
    program = tokens |> List.first() |> normalize_program()
    shell_features = shell_features(command || "")
    {risk_class, risk_hints} = classify_risk(program, tokens, command || "", shell_features)
    inferred_hosts = infer_network_hosts(tokens)

    requirements =
      raw
      |> requirements_for_raw(tokens, program, risk_class, inferred_hosts)
      |> Enum.uniq_by(&requirement_key/1)

    tags =
      requirements
      |> Enum.reduce(base_tags(raw, risk_class), fn %PermissionRequirement{} = requirement, acc ->
        requirement.tags
        |> MapSet.put(requirement.resource)
        |> MapSet.put(requirement.operation)
        |> MapSet.union(acc)
      end)

    %EnrichedPermissionEvent{
      raw: raw,
      tags: tags,
      requirements: requirements,
      command_tokens: tokens,
      command_program: program,
      command_prefixes: command_prefixes(tokens),
      shell_features: shell_features,
      requested_execution: raw.requested_execution,
      inferred_network_hosts: inferred_hosts,
      risk_class: risk_class,
      risk_hints: risk_hints
    }
  end

  @spec validate_new_rule(Rule.t() | map() | keyword(), [Rule.t() | map() | keyword()]) ::
          :ok | {:error, {:conflicting_rule, String.t()}}
  def validate_new_rule(rule, existing_rules) do
    rule = Rule.new(rule)
    fingerprint = predicate_fingerprint(rule)

    conflict =
      existing_rules
      |> Enum.map(&Rule.new/1)
      |> Enum.find(fn existing ->
        existing.level == rule.level and existing.scope == rule.scope and
          predicate_fingerprint(existing) == fingerprint and existing.effect != rule.effect
      end)

    case conflict do
      nil -> :ok
      %Rule{id: id} -> {:error, {:conflicting_rule, id}}
    end
  end

  @spec predicate_fingerprint(Rule.t() | map() | keyword()) :: String.t()
  def predicate_fingerprint(rule) do
    rule = Rule.new(rule)

    rule.predicates
    |> Enum.map(&canonical_predicate/1)
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec grant_key(Rule.t() | map() | keyword()) :: String.t()
  def grant_key(rule) do
    rule = Rule.new(rule)

    [
      "permission_rule",
      "v2",
      "level",
      rule.level,
      "scope",
      rule.scope,
      "effect",
      rule.effect,
      "predicates",
      predicate_fingerprint(rule)
    ]
    |> Enum.map(&to_string/1)
    |> Enum.join(":")
  end

  @spec grant_options(RawToolEvent.t() | EnrichedPermissionEvent.t() | map() | keyword()) :: [
          map()
        ]
  def grant_options(%EnrichedPermissionEvent{} = event) do
    event
    |> grant_proposals()
    |> grant_options_from_proposals()
  end

  def grant_options(raw_event) do
    raw_event
    |> enrich()
    |> grant_proposals()
    |> grant_options_from_proposals()
  end

  @spec rule_to_map(Rule.t() | map() | keyword()) :: map()
  def rule_to_map(rule) do
    rule = Rule.new(rule)

    %{
      "id" => rule.id,
      "level" => rule.level,
      "effect" => Atom.to_string(rule.effect),
      "scope" => Atom.to_string(rule.scope),
      "predicates" => Enum.map(rule.predicates, &predicate_to_map/1),
      "reason" => rule.reason,
      "created_by" => actor_to_map(rule.created_by),
      "created_at" => datetime_to_string(rule.created_at),
      "expires_at" => datetime_to_string(rule.expires_at),
      "source" => Atom.to_string(rule.source)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec raw_event_to_map(RawToolEvent.t() | map() | keyword()) :: map()
  def raw_event_to_map(raw_event) do
    raw = RawToolEvent.new(raw_event)

    %{
      "tool_name" => raw.tool_name,
      "params" => raw.params,
      "channel" => raw.channel,
      "chat_id" => raw.chat_id,
      "workspace" => raw.workspace,
      "cwd" => raw.cwd,
      "requested_execution" => Atom.to_string(raw.requested_execution),
      "actor" => actor_to_map(raw.actor),
      "metadata" => raw.metadata
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec event_from_request(Nex.Agent.Sandbox.Approval.Request.t()) :: RawToolEvent.t()
  def event_from_request(%Nex.Agent.Sandbox.Approval.Request{} = request) do
    case Map.get(request.metadata, "permission_event") ||
           Map.get(request.metadata, :permission_event) do
      %{} = event ->
        RawToolEvent.new(event)

      _ ->
        fallback_event_from_request(request)
    end
  end

  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(command) when is_binary(command) do
    command
    |> String.trim()
    |> then(fn
      "" ->
        []

      trimmed ->
        Regex.scan(~r/"([^"\\]*(?:\\.[^"\\]*)*)"|'([^']*)'|[^\s]+/, trimmed)
        |> Enum.map(fn
          [_full, double, ""] -> String.replace(double, "\\\"", "\"")
          [_full, "", single] -> single
          [full | _] -> full
        end)
    end)
  end

  def tokenize(command), do: tokenize(to_string(command || ""))

  defp fallback_event_from_request(%Nex.Agent.Sandbox.Approval.Request{kind: :path} = request) do
    RawToolEvent.new(%{
      tool_name: "filesystem",
      params: %{
        "path" => request.subject,
        "operation" => request.operation
      },
      channel: request.channel,
      chat_id: request.chat_id,
      workspace: request.workspace,
      actor: actor_from_request(request),
      metadata: request.metadata
    })
  end

  defp fallback_event_from_request(%Nex.Agent.Sandbox.Approval.Request{} = request) do
    RawToolEvent.new(%{
      tool_name: "bash",
      params: %{
        "command" => request.subject,
        "sandbox_permissions" => Map.get(request.metadata, "sandbox_permissions")
      },
      channel: request.channel,
      chat_id: request.chat_id,
      workspace: request.workspace,
      requested_execution: requested_execution_from_metadata(request.metadata),
      actor: actor_from_request(request),
      metadata: request.metadata
    })
  end

  defp command_from_raw(%RawToolEvent{params: %{"command" => command}}) when is_binary(command),
    do: command

  defp command_from_raw(_raw), do: nil

  defp requirements_for_raw(
         %RawToolEvent{tool_name: "bash"} = raw,
         tokens,
         program,
         risk,
         hosts
       ) do
    command = command_from_raw(raw) || ""

    command_requirement = %PermissionRequirement{
      id: "command:execute",
      resource: :command,
      operation: :execute,
      target: command,
      tags: MapSet.new([:command, raw.requested_execution, risk]),
      attrs: %{
        command: command,
        command_tokens: tokens,
        command_program: program,
        requested_execution: raw.requested_execution,
        risk_class: risk
      }
    }

    network_requirements =
      Enum.map(hosts, fn host ->
        %PermissionRequirement{
          id: "network:connect:#{host}",
          resource: :network,
          operation: :connect,
          target: host,
          tags: MapSet.new([:network, :connect, :network_fetch]),
          attrs: %{host: host}
        }
      end)

    [command_requirement] ++
      network_requirements ++ inferred_path_requirements(tokens, program, risk)
  end

  defp requirements_for_raw(
         %RawToolEvent{tool_name: tool_name, params: %{"path" => path}} = raw,
         _tokens,
         _program,
         _risk,
         _hosts
       )
       when is_binary(path) do
    operation = normalize_operation(Map.get(raw.params, "operation"))
    path_info = normalize_path_info(path)

    [
      %PermissionRequirement{
        id: "path:#{operation}:#{path_info.canonical_path}",
        resource: :path,
        operation: operation,
        target: path_info.canonical_path,
        tags: path_tags(operation),
        attrs: %{
          tool_name: tool_name,
          path: path_info.canonical_path,
          expanded_path: path_info.expanded_path,
          input_path: path,
          target_exists?: path_info.target_exists?
        }
      }
    ]
  end

  defp requirements_for_raw(
         %RawToolEvent{tool_name: tool_name},
         _tokens,
         _program,
         _risk,
         _hosts
       ) do
    [
      %PermissionRequirement{
        id: "tool:call:#{tool_name}",
        resource: :tool,
        operation: :call,
        target: tool_name,
        tags: MapSet.new([:tool, :call]),
        attrs: %{tool_name: tool_name}
      }
    ]
  end

  defp inferred_path_requirements(tokens, program, _risk) do
    operation =
      cond do
        program in ~w(cat head tail less more file stat wc) -> :read
        program in ~w(ls) -> :list
        program in ~w(find rg grep) -> :search
        program in ~w(touch cp mv tee install patch apply_patch) -> :write
        program in ~w(mkdir) -> :mkdir
        program in ~w(rm rmdir) -> :remove
        true -> nil
      end

    case operation do
      nil ->
        []

      operation ->
        tokens
        |> Enum.drop(1)
        |> Enum.reject(&option_token?/1)
        |> Enum.reject(&url_token?/1)
        |> Enum.filter(&path_like_token?/1)
        |> Enum.map(fn path ->
          info = normalize_path_info(path)

          %PermissionRequirement{
            id: "path:#{operation}:#{info.canonical_path}",
            resource: :path,
            operation: operation,
            target: info.canonical_path,
            tags: path_tags(operation),
            attrs: %{
              path: info.canonical_path,
              expanded_path: info.expanded_path,
              input_path: path,
              target_exists?: info.target_exists?
            }
          }
        end)
    end
  end

  defp requirement_key(%PermissionRequirement{} = requirement) do
    {requirement.resource, requirement.operation, requirement.target}
  end

  defp normalize_operation(value) when value in @known_operations, do: value

  defp normalize_operation(value) when is_binary(value) do
    Util.known_atom(value) || :read
  end

  defp normalize_operation(_value), do: :read

  defp path_tags(operation) when operation in @read_operations,
    do: MapSet.new([:filesystem, :path, operation, :read])

  defp path_tags(operation) when operation in [:write, :mkdir, :remove],
    do: MapSet.new([:filesystem, :path, operation, :write])

  defp path_tags(operation), do: MapSet.new([:filesystem, :path, operation, :read])

  defp base_tags(%RawToolEvent{tool_name: tool_name, requested_execution: execution}, risk) do
    MapSet.new([
      :tool,
      execution,
      risk,
      tool_tag(tool_name)
    ])
  end

  defp tool_tag("bash"), do: :command
  defp tool_tag("filesystem"), do: :filesystem
  defp tool_tag(_tool_name), do: :tool

  defp normalize_path_info(path) do
    expanded = Path.expand(path)

    case nearest_existing_ancestor(expanded) do
      {:ok, ancestor, suffix} ->
        canonical_ancestor = realpath_or_expand(ancestor)
        canonical_path = join_path([canonical_ancestor | suffix])

        %{
          expanded_path: expanded,
          canonical_path: canonical_path,
          target_exists?: suffix == []
        }

      :error ->
        %{
          expanded_path: expanded,
          canonical_path: expanded,
          target_exists?: false
        }
    end
  end

  defp nearest_existing_ancestor(path), do: nearest_existing_ancestor(path, [])

  defp nearest_existing_ancestor(path, suffix) do
    cond do
      File.exists?(path) ->
        {:ok, path, suffix}

      Path.dirname(path) == path ->
        :error

      true ->
        nearest_existing_ancestor(Path.dirname(path), [Path.basename(path) | suffix])
    end
  end

  defp realpath_or_expand(path) do
    path
    |> Path.expand()
    |> resolve_path_components(0)
  rescue
    _ -> Path.expand(path)
  end

  defp resolve_path_components(path, depth) when depth > 40, do: Path.expand(path)

  defp resolve_path_components(path, depth) do
    expanded = Path.expand(path)

    case Path.split(expanded) do
      ["/" | parts] -> resolve_parts(parts, "/", depth)
      parts -> resolve_parts(parts, "", depth)
    end
  end

  defp resolve_parts([], current, _depth), do: if(current == "", do: ".", else: current)

  defp resolve_parts([part | rest], current, depth) do
    candidate = Path.join(current, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        resolved_target =
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, Path.dirname(candidate))
          end

        [resolved_target | rest]
        |> join_path()
        |> resolve_path_components(depth + 1)

      {:error, _reason} ->
        resolve_parts(rest, candidate, depth)
    end
  end

  defp join_path([path]), do: path
  defp join_path(parts), do: Path.join(parts)

  defp decide_requirement(event, requirement, rules) do
    matches =
      rules
      |> Enum.flat_map(&match_rule(&1, event, requirement))

    case pick_winner(matches) do
      nil ->
        %RequirementDecision{
          requirement: requirement,
          action: :ask,
          reason: "No permission rule matched #{requirement.resource}:#{requirement.operation}."
        }

      %{rule: %Rule{} = rule} ->
        %RequirementDecision{
          requirement: requirement,
          action: rule.effect,
          matched_rule_ids: matches |> Enum.map(& &1.rule.id) |> Enum.reject(&(&1 == "")),
          winning_rule_id: if(rule.id == "", do: nil, else: rule.id),
          reason: decision_reason(rule)
        }
    end
  end

  defp fold_decision(%EnrichedPermissionEvent{} = event, requirement_decisions) do
    decisive =
      Enum.find(requirement_decisions, &(&1.action == :deny)) ||
        Enum.find(requirement_decisions, &(&1.action == :ask)) ||
        List.first(requirement_decisions)

    action = if decisive, do: decisive.action, else: :ask

    %Decision{
      action: action,
      matched_rule_ids:
        requirement_decisions
        |> Enum.flat_map(& &1.matched_rule_ids)
        |> Enum.uniq(),
      winning_rule_id: if(decisive, do: decisive.winning_rule_id),
      reason:
        if decisive do
          decisive.reason
        else
          "No permission requirements were derived."
        end,
      severity: severity(action),
      suggested_grants: grant_proposals(event),
      enriched_event: event,
      requirement_decisions: requirement_decisions
    }
  end

  defp match_rule(%Rule{} = rule, event, requirement) do
    cond do
      expired?(rule) ->
        []

      Enum.all?(rule.predicates, &predicate_matches?(&1, rule, event, requirement)) ->
        [
          %{
            rule: rule,
            specificity: specificity(rule.predicates),
            strictness: strictness(rule.effect)
          }
        ]

      true ->
        []
    end
  end

  defp expired?(%Rule{expires_at: nil}), do: false

  defp expired?(%Rule{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :lt

  defp predicate_matches?({:eq, field, expected}, _rule, event, requirement) do
    event_value(field, event, requirement) == expected
  end

  defp predicate_matches?({:in, field, expected_values}, _rule, event, requirement)
       when is_list(expected_values) do
    event_value(field, event, requirement) in expected_values
  end

  defp predicate_matches?({:contains, field, expected}, _rule, event, requirement) do
    case event_value(field, event, requirement) do
      values when is_list(values) -> expected in values
      %MapSet{} = values -> MapSet.member?(values, expected)
      _ -> false
    end
  end

  defp predicate_matches?({:tag_in, tags}, _rule, event, requirement) when is_list(tags) do
    tags = MapSet.new(tags)
    not MapSet.disjoint?(tags, MapSet.union(event.tags, requirement.tags))
  end

  defp predicate_matches?({:resource_eq, resource}, _rule, _event, requirement) do
    requirement.resource == resource
  end

  defp predicate_matches?({:operation_in, operations}, _rule, _event, requirement) do
    requirement.operation in operations
  end

  defp predicate_matches?({:path_eq, expected}, _rule, _event, requirement) do
    requirement.resource == :path and path_same?(requirement_path(requirement), expected)
  end

  defp predicate_matches?({:path_under, root}, _rule, _event, requirement) do
    requirement.resource == :path and path_within_root?(requirement_path(requirement), root)
  end

  defp predicate_matches?({:exact, :command_tokens, expected}, _rule, event, _requirement) do
    event.command_tokens == Util.normalize_tokens(expected)
  end

  defp predicate_matches?({:prefix, :command_tokens, expected}, _rule, event, _requirement) do
    prefix?(event.command_tokens, Util.normalize_tokens(expected))
  end

  defp predicate_matches?({:risk_in, risks}, _rule, event, _requirement) when is_list(risks) do
    event.risk_class in risks
  end

  defp predicate_matches?({:scope_eq, scope}, %Rule{scope: scope}, _event, _requirement), do: true
  defp predicate_matches?(_predicate, _rule, _event, _requirement), do: false

  defp event_value(:channel, %EnrichedPermissionEvent{raw: raw}, _requirement), do: raw.channel
  defp event_value(:chat_id, %EnrichedPermissionEvent{raw: raw}, _requirement), do: raw.chat_id

  defp event_value(:workspace, %EnrichedPermissionEvent{raw: raw}, _requirement),
    do: raw.workspace

  defp event_value(:cwd, %EnrichedPermissionEvent{raw: raw}, _requirement), do: raw.cwd

  defp event_value(:tool_name, %EnrichedPermissionEvent{raw: raw}, _requirement),
    do: raw.tool_name

  defp event_value(:actor_kind, %EnrichedPermissionEvent{raw: %{actor: actor}}, _requirement)
       when not is_nil(actor),
       do: actor.kind

  defp event_value(:actor_id, %EnrichedPermissionEvent{raw: %{actor: actor}}, _requirement)
       when not is_nil(actor),
       do: actor.id

  defp event_value(:requested_execution, event, _requirement), do: event.requested_execution
  defp event_value(:command_program, event, _requirement), do: event.command_program
  defp event_value(:command_tokens, event, _requirement), do: event.command_tokens
  defp event_value(:inferred_network_hosts, event, _requirement), do: event.inferred_network_hosts
  defp event_value(:risk_class, event, _requirement), do: event.risk_class
  defp event_value(:shell_features, event, _requirement), do: event.shell_features
  defp event_value(:tags, event, requirement), do: MapSet.union(event.tags, requirement.tags)
  defp event_value(:resource, _event, requirement), do: requirement.resource
  defp event_value(:operation, _event, requirement), do: requirement.operation
  defp event_value(:target, _event, requirement), do: requirement.target
  defp event_value(:path, _event, requirement), do: requirement_path(requirement)

  defp event_value(field, _event, %PermissionRequirement{attrs: attrs}) when is_atom(field) do
    Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field))
  end

  defp event_value(_field, _event, _requirement), do: nil

  defp requirement_path(%PermissionRequirement{attrs: attrs, target: target}) do
    Map.get(attrs, :path) || Map.get(attrs, "path") || target
  end

  defp path_same?(path, expected) when is_binary(path) and is_binary(expected) do
    realpath_or_expand(path) == realpath_or_expand(expected)
  end

  defp path_same?(_path, _expected), do: false

  defp path_within_root?(path, root) when is_binary(path) and is_binary(root) do
    path = realpath_or_expand(path)
    root = realpath_or_expand(root)
    path == root or root == "/" or String.starts_with?(path, root <> "/")
  end

  defp path_within_root?(_path, _root), do: false

  defp specificity(predicates) do
    length(predicates) * 100 + Enum.sum(Enum.map(predicates, &predicate_score/1))
  end

  defp predicate_score({:path_eq, _path}), do: 35
  defp predicate_score({:exact, :command_tokens, _tokens}), do: 30

  defp predicate_score({:path_under, path}) when is_binary(path),
    do: 16 + length(Path.split(path))

  defp predicate_score({:eq, _field, _value}), do: 20
  defp predicate_score({:resource_eq, _resource}), do: 18
  defp predicate_score({:operation_in, operations}), do: 12 + length(operations || [])

  defp predicate_score({:prefix, :command_tokens, tokens}),
    do: 10 + length(Util.normalize_tokens(tokens))

  defp predicate_score({:contains, _field, _value}), do: 8
  defp predicate_score({:tag_in, _tags}), do: 6
  defp predicate_score({:risk_in, _risks}), do: 5
  defp predicate_score(_predicate), do: 0

  defp pick_winner([]), do: nil

  defp pick_winner(matches) do
    Enum.max_by(matches, fn %{rule: rule, specificity: specificity, strictness: strictness} ->
      {rule.level, specificity, strictness, DateTime.to_unix(rule.created_at || epoch())}
    end)
  end

  defp decision_reason(%Rule{reason: reason}) when is_binary(reason) and reason != "",
    do: reason

  defp decision_reason(%Rule{effect: effect}), do: "Permission rule decided #{effect}."

  defp strictness(:deny), do: 3
  defp strictness(:ask), do: 2
  defp strictness(:allow), do: 1

  defp severity(:deny), do: :danger
  defp severity(:ask), do: :warning
  defp severity(:allow), do: :info

  defp grant_proposals(%EnrichedPermissionEvent{} = event) do
    event
    |> primary_requirement()
    |> case do
      %PermissionRequirement{resource: :path} = requirement ->
        path_grant_proposals(event, requirement)

      _requirement ->
        command_grant_proposals(event)
    end
  end

  defp primary_requirement(%EnrichedPermissionEvent{requirements: requirements}) do
    Enum.find(requirements, &(&1.resource == :command)) ||
      Enum.find(requirements, &(&1.resource == :path)) ||
      List.first(requirements)
  end

  defp command_grant_proposals(%EnrichedPermissionEvent{} = event) do
    exact_rule = command_proposal_rule(event, :exact)

    [
      %GrantProposal{
        id: "allow_thread_exact",
        label: "Allow #{execution_label(event)}exact `#{command_text(event)}` in this thread",
        rule: exact_rule,
        risk_summary: risk_summary(event)
      }
    ] ++ command_prefix_grant_proposals(event)
  end

  defp command_prefix_grant_proposals(
         %EnrichedPermissionEvent{risk_class: :network_fetch} = event
       ) do
    prefix_tokens = prefix_rule_tokens(event)

    if prefix_tokens != [] do
      [
        %GrantProposal{
          id: "allow_thread_prefix",
          label:
            "Allow #{execution_label(event)}`#{Enum.join(prefix_tokens, " ")} ...` in this thread",
          rule: command_proposal_rule(event, :prefix),
          risk_summary: risk_summary(event)
        }
      ]
    else
      []
    end
  end

  defp command_prefix_grant_proposals(_event), do: []

  defp path_grant_proposals(
         %EnrichedPermissionEvent{} = event,
         %PermissionRequirement{} = requirement
       ) do
    exact_rule = path_proposal_rule(event, requirement, :exact)
    under_rule = path_proposal_rule(event, requirement, :under)

    [
      %GrantProposal{
        id: "allow_thread_path_exact",
        label:
          "Allow #{operation_label(requirement.operation)} #{requirement_path(requirement)} in this thread",
        rule: exact_rule,
        risk_summary: risk_summary(event)
      }
    ] ++
      if under_rule do
        [
          %GrantProposal{
            id: "allow_thread_path_under",
            label:
              "Allow #{operation_group_label(requirement.operation)} under #{under_rule_path(requirement)} in this thread",
            rule: under_rule,
            risk_summary: risk_summary(event)
          }
        ]
      else
        []
      end
  end

  defp command_proposal_rule(%EnrichedPermissionEvent{raw: raw} = event, :exact) do
    Rule.new(
      id: "proposal:allow_thread_exact",
      effect: :allow,
      scope: :thread,
      predicates: [
        {:eq, :channel, raw.channel},
        {:eq, :chat_id, raw.chat_id},
        {:exact, :command_tokens, event.command_tokens},
        {:eq, :requested_execution, event.requested_execution}
      ],
      reason: "Allow #{execution_label(event)}exact command in this thread",
      source: :runtime
    )
  end

  defp command_proposal_rule(%EnrichedPermissionEvent{raw: raw} = event, :prefix) do
    Rule.new(
      id: "proposal:allow_thread_prefix",
      effect: :allow,
      scope: :thread,
      predicates: [
        {:eq, :channel, raw.channel},
        {:eq, :chat_id, raw.chat_id},
        {:prefix, :command_tokens, prefix_rule_tokens(event)},
        {:eq, :requested_execution, event.requested_execution}
      ],
      reason: "Allow #{execution_label(event)}command prefix in this thread",
      source: :runtime
    )
  end

  defp path_proposal_rule(
         %EnrichedPermissionEvent{raw: raw},
         %PermissionRequirement{} = requirement,
         :exact
       ) do
    Rule.new(
      id: "proposal:allow_thread_path_exact",
      effect: :allow,
      scope: :thread,
      predicates: [
        {:eq, :channel, raw.channel},
        {:eq, :chat_id, raw.chat_id},
        {:resource_eq, :path},
        {:operation_in, [requirement.operation]},
        {:path_eq, requirement_path(requirement)}
      ],
      reason: "Allow #{operation_label(requirement.operation)} path in this thread",
      source: :runtime
    )
  end

  defp path_proposal_rule(
         %EnrichedPermissionEvent{raw: raw},
         %PermissionRequirement{} = requirement,
         :under
       ) do
    if requirement.operation == :remove do
      nil
    else
      Rule.new(
        id: "proposal:allow_thread_path_under",
        effect: :allow,
        scope: :thread,
        predicates: [
          {:eq, :channel, raw.channel},
          {:eq, :chat_id, raw.chat_id},
          {:resource_eq, :path},
          {:operation_in, operation_group(requirement.operation)},
          {:path_under, under_rule_path(requirement)}
        ],
        reason: "Allow #{operation_group_label(requirement.operation)} under path in this thread",
        source: :runtime
      )
    end
  end

  defp grant_options_from_proposals(proposals) do
    proposals
    |> Enum.flat_map(fn
      %GrantProposal{rule: %Rule{} = rule} = proposal ->
        [
          %{
            "level" => grant_option_level(proposal.id),
            "proposal_id" => proposal.id,
            "scope" => Atom.to_string(rule.scope),
            "grant_key" => grant_key(rule),
            "subject" => proposal.label,
            "rule" => rule_to_map(rule)
          }
        ]

      _proposal ->
        []
    end)
  end

  defp grant_option_level(id) when id in ["allow_thread_prefix", "allow_thread_path_under"],
    do: "similar"

  defp grant_option_level(_id), do: "exact"

  defp operation_group(operation) when operation in @read_operations, do: @read_operations
  defp operation_group(:mkdir), do: [:mkdir, :write]
  defp operation_group(:write), do: [:write, :mkdir]
  defp operation_group(operation), do: [operation]

  defp operation_label(operation), do: operation |> to_string() |> String.replace("_", " ")

  defp operation_group_label(operation) when operation in @read_operations, do: "read"
  defp operation_group_label(operation), do: operation_label(operation)

  defp under_rule_path(%PermissionRequirement{operation: operation} = requirement)
       when operation in [:list, :search, :mkdir] do
    requirement_path(requirement)
  end

  defp under_rule_path(%PermissionRequirement{} = requirement) do
    path = requirement_path(requirement)
    if is_binary(path), do: Path.dirname(path), else: nil
  end

  defp execution_label(%EnrichedPermissionEvent{requested_execution: :elevated}),
    do: "unsandboxed "

  defp execution_label(_event), do: ""

  defp prefix_rule_tokens(%EnrichedPermissionEvent{command_tokens: [program, subcommand | _]}) do
    if option_like_or_value?(subcommand), do: [program], else: [program, subcommand]
  end

  defp prefix_rule_tokens(%EnrichedPermissionEvent{command_tokens: [program | _]}), do: [program]
  defp prefix_rule_tokens(_event), do: []

  defp command_text(%EnrichedPermissionEvent{raw: raw}), do: command_from_raw(raw) || ""

  defp option_like_or_value?(token) do
    String.starts_with?(token, ["-", "/", ".", "http://", "https://"])
  end

  defp option_token?(token), do: String.starts_with?(token, "-")
  defp url_token?(token), do: String.starts_with?(token, ["http://", "https://"])

  defp path_like_token?(token) do
    String.starts_with?(token, ["/", "./", "../", "~"]) or String.contains?(token, "/")
  end

  defp risk_summary(%EnrichedPermissionEvent{} = event) do
    ["risk=#{event.risk_class}", "execution=#{event.requested_execution}"]
    |> Enum.join(" ")
  end

  defp predicate_to_map({:eq, field, value}) do
    %{"op" => "eq", "field" => Atom.to_string(field), "value" => value}
  end

  defp predicate_to_map({:in, field, values}) do
    %{"op" => "in", "field" => Atom.to_string(field), "values" => values}
  end

  defp predicate_to_map({:contains, field, value}) do
    %{"op" => "contains", "field" => Atom.to_string(field), "value" => value}
  end

  defp predicate_to_map({:tag_in, tags}) do
    %{"op" => "tag_in", "tags" => Enum.map(tags, &Atom.to_string/1)}
  end

  defp predicate_to_map({:resource_eq, resource}) do
    %{"op" => "resource_eq", "resource" => Atom.to_string(resource)}
  end

  defp predicate_to_map({:operation_in, operations}) do
    %{"op" => "operation_in", "operations" => Enum.map(operations, &Atom.to_string/1)}
  end

  defp predicate_to_map({:path_eq, path}), do: %{"op" => "path_eq", "path" => path}
  defp predicate_to_map({:path_under, path}), do: %{"op" => "path_under", "path" => path}

  defp predicate_to_map({:exact, :command_tokens, tokens}) do
    %{"op" => "exact", "field" => "command_tokens", "tokens" => Util.normalize_tokens(tokens)}
  end

  defp predicate_to_map({:prefix, :command_tokens, tokens}) do
    %{"op" => "prefix", "field" => "command_tokens", "tokens" => Util.normalize_tokens(tokens)}
  end

  defp predicate_to_map({:risk_in, risks}) do
    %{"op" => "risk_in", "risks" => Enum.map(risks, &Atom.to_string/1)}
  end

  defp predicate_to_map({:scope_eq, scope}) do
    %{"op" => "scope_eq", "scope" => Atom.to_string(scope)}
  end

  defp predicate_to_map(predicate), do: %{"op" => "unknown", "value" => inspect(predicate)}

  defp rules_from_runtime(%{rules: rules}) when is_list(rules), do: rules
  defp rules_from_runtime(%{"rules" => rules}) when is_list(rules), do: rules
  defp rules_from_runtime(rules) when is_list(rules), do: rules
  defp rules_from_runtime(_runtime), do: []

  defp command_prefixes(tokens) do
    tokens
    |> Enum.reduce({[], []}, fn token, {current, prefixes} ->
      current = current ++ [token]
      {current, prefixes ++ [current]}
    end)
    |> elem(1)
  end

  defp prefix?(_tokens, []), do: false
  defp prefix?(tokens, prefix), do: Enum.take(tokens, length(prefix)) == prefix

  defp normalize_program(nil), do: nil
  defp normalize_program(program), do: program |> Path.basename() |> String.downcase()

  defp shell_features(command) do
    [
      {:pipeline, ~r/\|/},
      {:redirect, ~r/(^|[^>])>(?!\()|>>|<(?!!)/},
      {:command_substitution, ~r/`[^`]+`|\$\([^)]+\)/},
      {:process_substitution, ~r/(^|[\s;&|])(?:<|>)\([^)]+\)/},
      {:heredoc, ~r/<<<?\s*\w+/}
    ]
    |> Enum.reduce(MapSet.new(), fn {feature, regex}, acc ->
      if Regex.match?(regex, command), do: MapSet.put(acc, feature), else: acc
    end)
  end

  defp classify_risk(_program, _tokens, command, features) do
    cond do
      encoded_shell?(command) ->
        {:encoded_shell, ["Decoded content is piped into a shell."]}

      MapSet.member?(features, :command_substitution) ->
        {:command_substitution, ["Command substitution runs a nested command."]}

      MapSet.member?(features, :process_substitution) ->
        {:process_substitution, ["Process substitution starts a hidden helper process."]}

      shell_escape?(command) ->
        {:shell_escape, ["This starts another shell."]}

      interpreter_one_liner?(command) ->
        {:interpreter_code, ["Interpreter one-liners can read files or spawn processes."]}

      network_fetch?(command) ->
        {:network_fetch, []}

      write_command?(command) ->
        {:write, []}

      read_command?(command) ->
        {:read, []}

      true ->
        {:unknown, []}
    end
  end

  defp encoded_shell?(command) do
    Regex.match?(
      ~r/(?:^|[;&|]\s*)(?:base64|openssl\s+base64)\b[\s\S]*\|\s*(?:bash|sh|zsh|fish|csh|tcsh|dash|ksh)\b/i,
      command
    )
  end

  defp shell_escape?(command) do
    Regex.match?(~r/(^|[\s;&|])(?:bash|sh|zsh|fish|csh|tcsh|dash|ksh)\b/i, command)
  end

  defp interpreter_one_liner?(command) do
    Regex.match?(~r/(^|[\s;&|])(?:python3?|ruby|perl|node|php)\s+(-c|-e|-r)\b/i, command)
  end

  defp network_fetch?(command),
    do: Regex.match?(~r/(^|[\s;&|])(?:curl|wget|dokobot|gh)\b/i, command)

  defp write_command?(command) do
    Regex.match?(
      ~r/(^|[\s;&|])(?:rm|mv|cp|mkdir|rmdir|touch|tee|chmod|chown|install|patch|apply_patch)\b|(^|[\s;&|])find\b[\s\S]*\s-(?:delete|exec|execdir|ok|okdir)\b|>>| > /i,
      command
    )
  end

  defp read_command?(command) do
    Regex.match?(
      ~r/(^|[\s;&|])(?:cat|head|tail|less|more|ls|pwd|find|grep|rg|wc|file|stat|git)\b/i,
      command
    )
  end

  defp infer_network_hosts(tokens) do
    tokens
    |> Enum.flat_map(fn token ->
      case URI.parse(token) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
          [String.downcase(host)]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp canonical_predicate({:eq, field, value}), do: {:eq, field, canonical_value(value)}

  defp canonical_predicate({:in, field, values}),
    do: {:in, field, values |> Enum.map(&canonical_value/1) |> Enum.sort()}

  defp canonical_predicate({:contains, field, value}),
    do: {:contains, field, canonical_value(value)}

  defp canonical_predicate({:tag_in, tags}), do: {:tag_in, Enum.sort(tags)}
  defp canonical_predicate({:resource_eq, resource}), do: {:resource_eq, resource}

  defp canonical_predicate({:operation_in, operations}),
    do: {:operation_in, Enum.sort(operations)}

  defp canonical_predicate({:path_eq, path}), do: {:path_eq, Path.expand(path)}
  defp canonical_predicate({:path_under, path}), do: {:path_under, Path.expand(path)}

  defp canonical_predicate({:exact, :command_tokens, tokens}),
    do: {:exact, :command_tokens, Util.normalize_tokens(tokens)}

  defp canonical_predicate({:prefix, :command_tokens, tokens}),
    do: {:prefix, :command_tokens, Util.normalize_tokens(tokens)}

  defp canonical_predicate({:risk_in, risks}), do: {:risk_in, Enum.sort(risks)}
  defp canonical_predicate({:scope_eq, scope}), do: {:scope_eq, scope}
  defp canonical_predicate(predicate), do: predicate

  defp canonical_value(value) when is_binary(value), do: String.trim(value)
  defp canonical_value(value) when is_atom(value), do: value
  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)
  defp canonical_value(value), do: value

  defp actor_to_map(nil), do: nil

  defp actor_to_map(%ActorRef{} = actor) do
    %{
      "kind" => Atom.to_string(actor.kind),
      "channel" => actor.channel,
      "id" => actor.id,
      "display" => actor.display
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp requested_execution_from_metadata(metadata) when is_map(metadata) do
    if Map.get(metadata, "sandbox_permissions") == "require_escalated" or
         Map.get(metadata, :sandbox_permissions) == "require_escalated" do
      :elevated
    else
      :sandboxed
    end
  end

  defp requested_execution_from_metadata(_metadata), do: :sandboxed

  defp actor_from_request(%{authorized_actor: %{} = actor}) do
    ActorRef.new(%{
      kind: Map.get(actor, "kind") || Map.get(actor, :kind) || :user,
      channel: Map.get(actor, "channel") || Map.get(actor, :channel),
      id: Map.get(actor, "id") || Map.get(actor, :id),
      display: Map.get(actor, "display") || Map.get(actor, :display)
    })
  end

  defp actor_from_request(_request), do: nil

  defp epoch, do: ~U[1970-01-01 00:00:00Z]
end
