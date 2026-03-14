defmodule Nex.Agent.LayerContractHelper do
  @moduledoc false

  @layer_order ["identity", "AGENTS", "SOUL", "USER", "TOOLS", "MEMORY"]

  @matrix %{
    "identity" => %{
      authority: "code-owned and authoritative runtime identity",
      allowed: "Defines who the agent is and cannot be replaced by workspace content.",
      forbidden: [
        "User or workspace markdown replacing the agent name.",
        "Any layer overriding the canonical runtime identity."
      ]
    },
    "AGENTS" => %{
      authority: "system-level operating instructions",
      allowed: "System constraints and workflow guidance that operate under code-owned identity.",
      forbidden: [
        "Redefining or replacing canonical identity.",
        "Rewriting persona ownership away from SOUL boundaries."
      ]
    },
    "SOUL" => %{
      authority: "persona, values, and style",
      allowed: "Behavioral tone, values, and style preferences only.",
      forbidden: [
        "Declaring a different product/agent identity.",
        "Replacing code-owned identity with persona text."
      ]
    },
    "USER" => %{
      authority: "user profile and collaboration preferences",
      allowed: "User profile, collaboration preferences, timezone, and communication style.",
      forbidden: [
        "System policy or identity rewrites.",
        "Tool capability definitions."
      ]
    },
    "TOOLS" => %{
      authority: "tool reference",
      allowed: "Tool descriptions, parameters, and usage references only.",
      forbidden: [
        "Identity or persona policy.",
        "Durable project memory facts."
      ]
    },
    "MEMORY" => %{
      authority: "durable environment, project, and workflow facts",
      allowed: "Persistent factual context about environment, project, and workflow.",
      forbidden: [
        "Identity definitions.",
        "Persona/style ownership that belongs to SOUL."
      ]
    }
  }

  @diagnostics_policy "Read and compose tolerate legacy files but emit diagnostics for out-of-layer or conflicting content."

  @write_policy "New writes must satisfy layer ownership; invalid writes are rejected rather than silently normalized."

  def layer_order, do: @layer_order
  def matrix, do: @matrix
  def diagnostics_policy, do: @diagnostics_policy
  def write_policy, do: @write_policy
end
