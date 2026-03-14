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

    For user profile preferences, use user_update instead.
    For persona tone/values/style guidance, use soul_update instead.
    Identity declarations or replacements do not belong in memory.

    Use `action=append` for incremental facts and `action=set` for full document regeneration.
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
            enum: ["append", "set"],
            description: "How to update memory"
          },
          content: %{
            type: "string",
            description: "Memory content for append/set operations"
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
