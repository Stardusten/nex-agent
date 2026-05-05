defmodule Nex.Agent.Capability.Tool.Core.PermissionRevokeRule do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Capability.Tool.Core.PermissionRuleInspector
  alias Nex.Agent.Sandbox.Approval

  def name, do: "permission__revoke_rule"

  def description,
    do: "Revoke a removable approved permission rule by rule_ref."

  def category, do: :base
  def surfaces, do: [:all, :base]

  def definition do
    %{
      name: name(),
      description:
        "Revoke a removable allow rule previously shown by permission__list_rules. This tool only removes ordinary owner-approved allow rules; it cannot remove deny, ask, or system-level rules.",
      parameters: %{
        type: "object",
        properties: %{
          rule_ref: %{
            type: "string",
            description: "Stable rule_ref copied from permission__list_rules."
          },
          reason: %{
            type: "string",
            description: "Short reason for revoking the rule."
          }
        },
        required: ["rule_ref"]
      }
    }
  end

  def execute(%{"rule_ref" => rule_ref} = args, ctx) when is_binary(rule_ref) and rule_ref != "" do
    with {:ok, workspace, session_key} <- PermissionRuleInspector.permission_context(args, ctx),
         {:ok, entry} <- Approval.revoke_rule(workspace, session_key, rule_ref, approval_opts(ctx)) do
      {:ok,
       %{
         status: "revoked",
         revoked_rule: PermissionRuleInspector.rule_summary(entry, ctx),
         reason: Map.get(args, "reason")
       }}
    else
      {:error, :permission_rule_not_found} ->
        {:error, "permission rule was not found in the current permission context"}

      {:error, :permission_rule_revoke_cannot_remove_non_allow_rule} ->
        {:error, "permission__revoke_rule cannot remove deny or ask rules"}

      {:error, :permission_rule_revoke_not_allowed} ->
        {:error, "permission__revoke_rule can only remove ordinary owner-approved allow rules"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "permission rule revoke failed: #{inspect(reason)}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "rule_ref is required"}

  defp approval_opts(ctx) do
    case Map.get(ctx, :approval_server) || Map.get(ctx, "approval_server") do
      nil -> []
      server -> [server: server]
    end
  end
end
