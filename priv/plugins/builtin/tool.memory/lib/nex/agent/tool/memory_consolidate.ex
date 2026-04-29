defmodule Nex.Agent.Tool.MemoryConsolidate do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.{
    Runtime.Config,
    Knowledge.Memory,
    Conversation.Session,
    Conversation.SessionManager
  }

  alias Nex.Agent.Knowledge.Memory.Notice
  alias Nex.Agent.Knowledge.Memory.Updater, as: MemoryUpdater

  @default_model "claude-sonnet-4-20250514"

  def name, do: "memory_consolidate"

  def description do
    """
    Immediately run a memory refresh for the current session to trigger memory consolidation.

    Use this when the user explicitly asks to trigger memory refresh now:
    - "trigger memory refresh" / "refresh memory now"
    - "trigger memory consolidation"
    - "立即更新记忆" / "现在刷新记忆"
    - "触发记忆整理"

    This is not a full rebuild. Use `memory_status` to only check status.
    Use `memory_rebuild` only for a full rebuild of MEMORY.md from the full session history.
    """
  end

  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          session_key: %{
            type: "string",
            description: "Optional session key to consolidate. Defaults to the current session."
          }
        }
      }
    }
  end

  def execute(args, ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")
    provider = Map.get(ctx, :provider) || Map.get(ctx, "provider") || :anthropic
    model = Map.get(ctx, :model) || Map.get(ctx, "model") || @default_model
    api_key = Map.get(ctx, :api_key) || Map.get(ctx, "api_key")
    base_url = Map.get(ctx, :base_url) || Map.get(ctx, "base_url")
    provider_options = Map.get(ctx, :provider_options) || Map.get(ctx, "provider_options") || []
    llm_call_fun = Map.get(ctx, :llm_call_fun) || Map.get(ctx, "llm_call_fun")

    req_llm_stream_text_fun =
      Map.get(ctx, :req_llm_stream_text_fun) || Map.get(ctx, "req_llm_stream_text_fun")

    session_key =
      Map.get(args, "session_key") ||
        Map.get(ctx, :session_key) ||
        Map.get(ctx, "session_key") ||
        derive_session_key(ctx)

    with {:ok, session_key} <- validate_session_key(session_key) do
      case fetch_session(session_key, workspace) do
        nil ->
          {:error, "Session not found: #{session_key}"}

        session ->
          updater = MemoryUpdater.status(session_key, workspace: workspace)

          if updater["status"] in ["running", "queued"] do
            {:ok,
             result_payload(
               session_key,
               "already_running",
               "memory_refresh_#{updater["status"]}",
               session,
               session,
               workspace
             )}
          else
            runtime = memory_runtime(ctx, provider, model, api_key, base_url, provider_options)

            opts =
              [
                api_key: runtime.api_key,
                base_url: runtime.base_url,
                provider_options: runtime.provider_options,
                workspace: workspace,
                model_role: runtime.model_role
              ]
              |> maybe_put(:llm_call_fun, llm_call_fun)
              |> maybe_put(:req_llm_stream_text_fun, req_llm_stream_text_fun)

            case Memory.refresh(session, runtime.provider, runtime.model, opts) do
              {:ok, updated_session, refresh_result} ->
                SessionManager.save_sync(updated_session, workspace: workspace)

                Notice.maybe_send(refresh_result,
                  workspace: workspace,
                  session_key: updated_session.key,
                  channel: Map.get(ctx, :channel) || Map.get(ctx, "channel"),
                  chat_id: Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id"),
                  notify: user_visible_context?(ctx),
                  source: "memory_consolidate_tool"
                )

                {:ok,
                 result_payload(
                   session_key,
                   if(refresh_result.status == :updated, do: "refreshed", else: "noop"),
                   if(refresh_result.status == :updated, do: "ok", else: "no_new_memory"),
                   session,
                   updated_session,
                   workspace,
                   refresh_result
                 )}

              {:error, reason} ->
                {:error, reason}
            end
          end
      end
    end
  end

  defp result_payload(
         session_key,
         status,
         reason,
         before_session,
         after_session,
         workspace,
         refresh_result \\ nil
       ) do
    %{
      "session_key" => session_key,
      "status" => status,
      "reason" => reason,
      "last_reviewed_before" => before_session.last_consolidated,
      "last_reviewed_after" => after_session.last_consolidated,
      "memory_bytes" => byte_size(Memory.read_long_term(workspace: workspace)),
      "summary" => refresh_result && refresh_result.summary,
      "model_role" => refresh_result && refresh_result.model_role,
      "provider" => refresh_result && refresh_result.provider,
      "model" => refresh_result && refresh_result.model
    }
  end

  defp memory_runtime(ctx, fallback_provider, fallback_model, api_key, base_url, provider_options) do
    config = Map.get(ctx, :config) || Map.get(ctx, "config")

    case config && Config.memory_model_runtime(config) do
      %{provider: provider, model_id: model} = runtime ->
        %{
          provider: provider,
          model: model,
          api_key: runtime.api_key,
          base_url: runtime.base_url,
          provider_options: runtime.provider_options,
          model_role: "memory"
        }

      _ ->
        %{
          provider: fallback_provider,
          model: fallback_model,
          api_key: api_key,
          base_url: base_url,
          provider_options: provider_options,
          model_role: "runtime"
        }
    end
  end

  defp fetch_session(session_key, workspace) do
    session_opts = workspace_opts(workspace)

    if Process.whereis(SessionManager) do
      SessionManager.get(session_key, session_opts) || Session.load(session_key, session_opts)
    else
      Session.load(session_key, session_opts)
    end
  end

  defp validate_session_key(nil), do: {:error, "session_key is required"}
  defp validate_session_key(""), do: {:error, "session_key is required"}
  defp validate_session_key(session_key), do: {:ok, session_key}

  defp derive_session_key(ctx) do
    channel = Map.get(ctx, :channel) || Map.get(ctx, "channel")
    chat_id = Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id")

    if present?(channel) and present?(chat_id) do
      "#{channel}:#{chat_id}"
    else
      nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp user_visible_context?(ctx) do
    metadata = Map.get(ctx, :metadata) || Map.get(ctx, "metadata") || %{}
    tools_filter = Map.get(ctx, :tools_filter) || Map.get(ctx, "tools_filter")

    not (Map.get(metadata, "_from_cron") == true or
           Map.get(metadata, "_from_subagent") == true or
           Map.get(metadata, "_follow_up") == true or
           tools_filter in [:cron, :follow_up, :subagent])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp workspace_opts(nil), do: []
  defp workspace_opts(workspace), do: [workspace: workspace]
end
