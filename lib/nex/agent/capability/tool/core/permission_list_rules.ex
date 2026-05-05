defmodule Nex.Agent.Capability.Tool.Core.PermissionListRules do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Capability.Tool.Core.PermissionRuleInspector
  alias Nex.Agent.Sandbox.Approval

  def name, do: "permission__list_rules"

  def description,
    do: "List approved permission rules as a semantic view without exposing storage internals."

  def category, do: :base
  def surfaces, do: [:all, :base]

  def definition do
    %{
      name: name(),
      description:
        "List approved permission rules in the current permission context. This returns a semantic rule view and stable rule_ref values for permission__revoke_rule; it does not expose permission storage internals.",
      parameters: %{
        type: "object",
        properties: %{
          scope: %{
            type: "string",
            enum: ["current", "workspace"],
            description:
              "current lists rules that apply to this thread/channel/workspace. workspace lists all rules visible in the current workspace.",
            default: "current"
          },
          resource: %{
            type: "string",
            enum: ["path", "command"],
            description: "Optional resource filter."
          },
          persistence: %{
            type: "string",
            enum: ["session", "always"],
            description: "Optional persistence filter."
          },
          effect: %{
            type: "string",
            enum: ["allow", "ask", "deny"],
            description: "Optional effect filter."
          }
        }
      }
    }
  end

  def execute(args, ctx) when is_map(args) do
    with {:ok, workspace, session_key} <- PermissionRuleInspector.permission_context(args, ctx) do
      entries =
        workspace
        |> Approval.list_rules(session_key, approval_opts(ctx))
        |> filter_entries(args, ctx)

      {:ok,
       %{
         count: length(entries),
         rules: Enum.map(entries, &PermissionRuleInspector.rule_summary(&1, ctx)),
         note:
           "This is a semantic permission view. Use rule_ref with permission__revoke_rule when a removable allow rule should be deleted."
       }}
    end
  end

  def execute(_args, ctx), do: execute(%{}, ctx)

  defp filter_entries(entries, args, ctx) do
    entries
    |> filter_scope(Map.get(args, "scope") || "current", ctx)
    |> filter_value(:persistence, Map.get(args, "persistence"))
    |> filter_rule_attr(:effect, Map.get(args, "effect"))
    |> filter_resource(Map.get(args, "resource"))
  end

  defp filter_scope(entries, "workspace", _ctx), do: entries

  defp filter_scope(entries, _scope, ctx) do
    Enum.filter(entries, fn
      %{persistence: :session} ->
        true

      %{rule: rule} ->
        PermissionRuleInspector.rule_applies_to_context?(rule, ctx)
    end)
  end

  defp filter_value(entries, _key, nil), do: entries

  defp filter_value(entries, key, value) when is_binary(value) do
    Enum.filter(entries, &(Map.get(&1, key) |> Atom.to_string() == value))
  end

  defp filter_rule_attr(entries, _key, nil), do: entries

  defp filter_rule_attr(entries, key, value) when is_binary(value) do
    Enum.filter(entries, fn %{rule: rule} ->
      rule |> Map.get(key) |> Atom.to_string() == value
    end)
  end

  defp filter_resource(entries, nil), do: entries

  defp filter_resource(entries, resource) when is_binary(resource) do
    resource = String.to_existing_atom(resource)

    Enum.filter(entries, fn %{rule: rule} ->
      Enum.any?(rule.predicates, &(&1 == {:resource_eq, resource}))
    end)
  rescue
    ArgumentError -> []
  end

  defp approval_opts(ctx) do
    case Map.get(ctx, :approval_server) || Map.get(ctx, "approval_server") do
      nil -> []
      server -> [server: server]
    end
  end
end
