defmodule Nex.Agent.Tool.MemoryWrite do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Memory

  def name, do: "memory_write"

  def description do
    """
    Persist important long-term information to MEMORY.md.

    Use this for durable facts that should survive future sessions:
    - Environment setup and project conventions
    - Workflow lessons and discovered patterns
    - Important context about ongoing work
    - Lessons learned from mistakes

    For user preferences and profile information, use user_update instead.
    For identity and behavioral guidelines, use soul_update instead.

    Skip one-off outputs and temporary data.
    """
  end

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["add", "replace", "remove"],
            description: "How to update memory"
          },
          content: %{
            type: "string",
            description: "Memory content for add/replace operations"
          },
          old_text: %{
            type: "string",
            description: "Exact text to replace or remove (required for replace/remove)"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(%{"action" => action} = args, ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")

    # Always use "memory" target
    case Memory.apply_memory_write(
           action,
           "memory",
           Map.get(args, "content"),
           Map.get(args, "old_text"),
           workspace: workspace
         ) do
      {:ok, %{action: saved_action}} ->
        {:ok, "Memory #{saved_action} saved."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_args, _ctx), do: {:error, "action is required"}
end
