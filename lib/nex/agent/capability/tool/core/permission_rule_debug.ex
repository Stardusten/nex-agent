defmodule Nex.Agent.Capability.Tool.Core.PermissionRuleDebug do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Capability.Tool.Core.PermissionRuleInspector
  alias Nex.Agent.Sandbox.{Approval, PermissionRule}

  def name, do: "permission__debug__decision"

  def description,
    do:
      "Explain how the permission rule engine evaluates a raw tool event, optionally with candidate rules."

  def category, do: :base
  def surfaces, do: [:all, :base]

  def definition do
    %{
      name: name(),
      description:
        "Debug permission rule behavior for a tool event. It evaluates current approved permission state and, when candidate_rules are supplied, also evaluates candidate-only and combined decisions. This tool does not expose or depend on permission internals.",
      parameters: %{
        type: "object",
        properties: %{
          event: %{
            type: "object",
            description:
              "Raw tool event to inspect. For bash, pass command and optional sandbox_permissions/requested_execution. For path tools, pass path and operation.",
            properties: %{
              tool_name: %{type: "string", description: "Tool name such as bash or filesystem."},
              command: %{type: "string", description: "Shell command for bash events."},
              path: %{type: "string", description: "Path for filesystem-style events."},
              operation: %{
                type: "string",
                description: "Path operation such as read, list, search, write, mkdir, or remove."
              },
              sandbox_permissions: %{
                type: "string",
                enum: ["default", "require_escalated"],
                description: "Use require_escalated to model unsandboxed bash."
              },
              requested_execution: %{
                type: "string",
                enum: ["sandboxed", "elevated"],
                description: "Explicit execution mode when known."
              }
            }
          },
          candidate_rule: %{
            type: "object",
            description:
              "Optional single permission__add_rule-style candidate to test against this event."
          },
          candidate_rules: %{
            type: "array",
            items: %{type: "object"},
            description:
              "Optional permission__add_rule-style candidates to evaluate as candidate-only and combined decisions."
          }
        },
        required: ["event"]
      }
    }
  end

  def execute(%{"event" => event} = args, ctx) when is_map(event) do
    raw_event = PermissionRuleInspector.raw_event(event, ctx)

    with {:ok, workspace, session_key} <- PermissionRuleInspector.permission_context(raw_event, ctx),
         {:ok, candidate_rules, subjects} <- PermissionRuleInspector.candidate_rules(args, ctx) do
      current =
        Approval.debug_decision(
          workspace,
          session_key,
          raw_event,
          approval_opts(ctx)
        )

      result = %{
        current_decision:
          PermissionRuleInspector.result(current,
            source: "current_approved_rules",
            candidate_rule_subjects: []
          )
      }

      result =
        if candidate_rules == [] do
          result
        else
          candidate_only = PermissionRule.decide(raw_event, candidate_rules)

          combined =
            Approval.debug_decision(
              workspace,
              session_key,
              raw_event,
              approval_opts(ctx) ++ [extra_rules: candidate_rules]
            )

          result
          |> Map.put(
            :candidate_only_decision,
            PermissionRuleInspector.result(candidate_only,
              source: "candidate_rules",
              candidate_rule_subjects: subjects,
              rule_count: length(candidate_rules)
            )
          )
          |> Map.put(
            :combined_decision,
            PermissionRuleInspector.result(combined,
              source: "current_approved_rules_plus_candidates",
              candidate_rule_subjects: subjects,
              rule_count: length(candidate_rules)
            )
          )
        end

      {:ok, result}
    end
  end

  def execute(_args, _ctx), do: {:error, "event is required"}

  defp approval_opts(ctx) do
    case Map.get(ctx, :approval_server) || Map.get(ctx, "approval_server") do
      nil -> []
      server -> [server: server]
    end
  end
end
