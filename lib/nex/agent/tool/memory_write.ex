defmodule Nex.Agent.Tool.MemoryWrite do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Memory
  alias Nex.Agent.ControlPlane.Log
  alias Nex.Agent.Memory.Notice
  require Log

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
      {:ok, %{action: saved_action} = write_result} ->
        maybe_emit_changed(write_result, ctx, workspace)
        {:ok, "Memory #{saved_action} saved."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_args, _ctx), do: {:error, "action is required"}

  defp maybe_emit_changed(%{changed: true} = write_result, ctx, workspace) do
    result = %{
      status: :updated,
      summary: Map.get(write_result, :content),
      before_hash: Map.get(write_result, :before_hash),
      after_hash: Map.get(write_result, :after_hash),
      memory_bytes: Map.get(write_result, :memory_bytes),
      model_role: "tool",
      provider: ctx |> get_ctx(:provider) |> to_string(),
      model: ctx |> get_ctx(:model) |> to_string()
    }

    Log.info(
      "memory.write.changed",
      %{
        "source" => "memory_write_tool",
        "summary" => Notice.summary(result.summary),
        "before_hash" => result.before_hash,
        "after_hash" => result.after_hash,
        "memory_bytes" => result.memory_bytes,
        "model_role" => result.model_role,
        "provider" => result.provider,
        "model" => result.model
      },
      workspace: workspace,
      session_key: get_ctx(ctx, :session_key)
    )

    Notice.maybe_send(result,
      workspace: workspace,
      session_key: get_ctx(ctx, :session_key),
      channel: get_ctx(ctx, :channel),
      chat_id: get_ctx(ctx, :chat_id),
      notify: user_visible_context?(ctx),
      source: "memory_write_tool"
    )

    :ok
  end

  defp maybe_emit_changed(_write_result, _ctx, _workspace), do: :ok

  defp user_visible_context?(ctx) do
    metadata = get_ctx(ctx, :metadata) || %{}
    tools_filter = get_ctx(ctx, :tools_filter)

    not (Map.get(metadata, "_from_cron") == true or
           Map.get(metadata, "_from_subagent") == true or
           Map.get(metadata, "_follow_up") == true or
           tools_filter in [:cron, :follow_up, :subagent])
  end

  defp get_ctx(ctx, key) do
    Map.get(ctx, key) || Map.get(ctx, to_string(key))
  end
end
