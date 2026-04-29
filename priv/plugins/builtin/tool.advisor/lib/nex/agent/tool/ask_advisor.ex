defmodule Nex.Agent.Tool.AskAdvisor do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.{Runtime.Config, Conversation.Session, Conversation.SessionManager}
  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Capability.Subagent.{Profile, Profiles}
  alias Nex.Agent.Turn.LLM.ProviderProfile

  @default_context_window 12
  @max_context_chars 32_000
  @max_advisor_iterations 4

  def name, do: "ask_advisor"

  def description do
    "Ask an internal advisor model for concise guidance. The answer is returned to this run and is not sent to the user directly."
  end

  def category, do: :base

  def definition do
    definition([])
  end

  def definition(opts) do
    profile_names =
      opts
      |> Keyword.get(:subagent_profiles, %{})
      |> profile_names()
      |> include_default_advisor()

    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          question: %{
            type: "string",
            description: "Specific question for the advisor."
          },
          context_mode: %{
            type: "string",
            enum: ["full", "recent", "none"],
            description:
              "How much parent session context to inherit automatically. Defaults to recent."
          },
          context_window: %{
            type: "integer",
            minimum: 1,
            description:
              "Number of recent parent messages to include when context_mode is recent."
          },
          profile: profile_schema(profile_names),
          context: %{
            type: "string",
            description: "Optional caller-provided context to append after inherited context."
          },
          model_key: %{
            type: "string",
            description: "Optional config model key override for this advisor call."
          }
        },
        required: ["question"]
      }
    }
  end

  def execute(%{"question" => question} = args, ctx) when is_binary(question) do
    started_at = System.monotonic_time(:millisecond)
    do_execute(args, ctx, question, started_at)
  end

  def execute(_args, _ctx), do: {:error, "question is required"}

  defp do_execute(args, ctx, question, started_at) do
    with {:ok, question} <- normalize_question(question),
         {:ok, context_mode} <- normalize_context_mode(Map.get(args, "context_mode")),
         {:ok, profile} <- resolve_profile(args, ctx),
         {:ok, model_runtime} <- resolve_model_runtime(args, profile, ctx) do
      context_window = context_window(args, profile)
      prompt = build_prompt(question, context_mode, context_window, args, ctx, profile)
      advisor_run_id = "advisor:#{ctx_value(ctx, :run_id) || call_id()}"
      runner_opts = runner_opts(model_runtime, profile, ctx, started_at, advisor_run_id)
      attrs = observation_attrs(question, context_mode, context_window, profile, model_runtime)
      emit(:info, "advisor.call.started", attrs, ctx)

      case Nex.Agent.Turn.Runner.run(Session.new(advisor_run_id), prompt, runner_opts) do
        {:ok, result, _session} ->
          advice = render_result(result)

          emit(
            :info,
            "advisor.call.finished",
            attrs
            |> Map.put("duration_ms", duration_since(started_at))
            |> Map.put("result_status", "ok")
            |> Map.put("advice_chars", String.length(advice)),
            ctx
          )

          {:ok, advice}

        {:error, reason, _session} ->
          message = "advisor call failed: #{format_reason(reason)}"

          emit(
            :error,
            "advisor.call.failed",
            attrs
            |> Map.put("duration_ms", duration_since(started_at))
            |> Map.put("result_status", "error")
            |> Map.put("reason_type", reason_type(reason))
            |> Map.put("error_summary", format_reason(reason)),
            ctx
          )

          {:error, message}
      end
    else
      {:error, reason} ->
        emit(
          :error,
          "advisor.call.failed",
          %{
            "duration_ms" => duration_since(started_at),
            "result_status" => "error",
            "reason_type" => reason_type(reason),
            "error_summary" => format_reason(reason)
          },
          ctx
        )

        {:error, format_reason(reason)}
    end
  rescue
    e ->
      emit(
        :error,
        "advisor.call.failed",
        %{
          "duration_ms" => duration_since(started_at),
          "result_status" => "error",
          "reason_type" => "exception",
          "error_summary" => Exception.message(e)
        },
        ctx
      )

      {:error, "advisor call failed: #{Exception.message(e)}"}
  end

  defp resolve_profile(args, ctx) do
    profiles = profiles_from_ctx(ctx)

    case normalize_text(Map.get(args, "profile")) do
      nil ->
        {:ok, Map.get(profiles, "advisor") || default_advisor_profile()}

      "advisor" ->
        {:ok, Map.get(profiles, "advisor") || default_advisor_profile()}

      name ->
        normalized = Profile.normalize_name(name)

        case normalized && Map.get(profiles, normalized) do
          %Profile{} = profile -> {:ok, profile}
          _ -> {:error, "unknown advisor profile: #{name}"}
        end
    end
  end

  defp profiles_from_ctx(ctx) do
    case ctx_value(ctx, :runtime_snapshot) do
      %Snapshot{subagents: %{profiles: profiles}} when is_map(profiles) ->
        profiles

      _ ->
        Profiles.load(config_from_ctx(ctx), workspace: workspace_from_ctx(ctx))
    end
  end

  defp resolve_model_runtime(args, %Profile{} = profile, ctx) do
    config = config_from_ctx(ctx)

    explicit_key =
      normalize_text(Map.get(args, "model_key")) ||
        normalize_text(profile.model_key)

    cond do
      is_binary(explicit_key) and match?(%Config{}, config) ->
        case Config.model_runtime(config, explicit_key) do
          {:ok, runtime} -> {:ok, runtime}
          {:error, _reason} -> {:error, "unknown advisor model_key: #{explicit_key}"}
        end

      is_binary(explicit_key) ->
        {:error, "model_key requires runtime config"}

      true ->
        runtime =
          profile_model_runtime(profile, config) ||
            advisor_model_runtime(config) ||
            fallback_model_runtime(ctx)

        {:ok, runtime}
    end
  end

  defp profile_model_runtime(%Profile{model_role: role}, %Config{} = config)
       when role not in [nil, :inherit] do
    Config.model_role(config, role)
  end

  defp profile_model_runtime(_profile, _config), do: nil

  defp advisor_model_runtime(%Config{} = config), do: Config.advisor_model_runtime(config)
  defp advisor_model_runtime(_config), do: nil

  defp fallback_model_runtime(ctx) do
    provider = ctx_value(ctx, :provider) || :anthropic

    %{
      provider: provider,
      model_id: ctx_value(ctx, :model) || ProviderProfile.default_model(provider),
      api_key: ctx_value(ctx, :api_key),
      base_url: ctx_value(ctx, :base_url),
      provider_options: ctx_value(ctx, :provider_options) || []
    }
  end

  defp build_prompt(question, context_mode, context_window, args, ctx, profile) do
    [
      String.trim(profile.prompt || default_prompt()),
      "Question:\n#{question}",
      inherited_context_block(context_mode, context_window, ctx),
      context_block("Caller-provided advisor context", Map.get(args, "context")),
      "Return concise advice for the current runner. Do not send a user-visible message."
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp default_prompt do
    """
    You are an internal advisor for the current agent run.

    Give practical guidance, risks, and next steps. Do not execute work, write files, send messages, update memory, or claim ownership of the task.
    """
  end

  defp default_advisor_profile do
    %Profile{
      name: "advisor",
      description:
        "Give concise internal guidance, risk review, and next steps for the current owner run.",
      prompt: default_prompt(),
      model_role: :advisor,
      tools_filter: :follow_up,
      tool_allowlist: [],
      context_mode: :blank,
      context_window: @default_context_window,
      return_mode: :silent,
      max_iterations: @max_advisor_iterations,
      source: :builtin
    }
  end

  defp inherited_context_block("none", _context_window, _ctx), do: nil

  defp inherited_context_block(context_mode, context_window, ctx) do
    session_key = ctx_value(ctx, :session_key)
    workspace = workspace_from_ctx(ctx)

    messages =
      case load_parent_session(session_key, workspace) do
        %Session{} = session ->
          limit =
            case context_mode do
              "full" -> max(length(session.messages), 1)
              "recent" -> context_window
            end

          Session.get_history(session, limit)

        nil ->
          []
      end

    rendered =
      messages
      |> Enum.map_join("\n", &render_message/1)
      |> truncate_context()

    """
    Advisor context from parent session (mode=#{context_mode}, session_key=#{session_key || "-"}, messages=#{length(messages)}):
    #{if rendered == "", do: "(no parent session messages available)", else: rendered}
    """
    |> String.trim()
  end

  defp context_block(_title, value) when value in [nil, ""], do: nil

  defp context_block(title, value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      "#{title}:\n#{trimmed}"
    end
  end

  defp context_block(_title, _value), do: nil

  defp load_parent_session(session_key, _workspace) when session_key in [nil, ""], do: nil

  defp load_parent_session(session_key, workspace) do
    opts = if is_binary(workspace), do: [workspace: workspace], else: []

    cached =
      if Process.whereis(SessionManager) do
        SessionManager.get(session_key, opts)
      end

    cached || Session.load(session_key, opts)
  end

  defp render_message(message) when is_map(message) do
    role = Map.get(message, "role") || "unknown"
    name = Map.get(message, "name")
    label = if is_binary(name) and name != "", do: "#{role}:#{name}", else: role
    content = render_value(Map.get(message, "content", ""))

    "[#{label}] #{content}"
  end

  defp render_message(message), do: render_value(message)

  defp runner_opts(model_runtime, profile, ctx, started_at, advisor_run_id) do
    provider = runtime_value(model_runtime, :provider) || :anthropic
    provider_options = runtime_value(model_runtime, :provider_options) || []

    [
      provider: provider,
      model: runtime_value(model_runtime, :model_id) || ProviderProfile.default_model(provider),
      api_key: runtime_value(model_runtime, :api_key),
      base_url: runtime_value(model_runtime, :base_url),
      model_runtime: model_runtime,
      provider_options: Keyword.merge(provider_options, profile.provider_options || []),
      max_iterations: profile.max_iterations || @max_advisor_iterations,
      channel: "system",
      chat_id: "advisor",
      session_key: advisor_run_id,
      run_id: advisor_run_id,
      cancel_ref: ctx_value(ctx, :cancel_ref),
      workspace: workspace_from_ctx(ctx),
      cwd: ctx_value(ctx, :cwd),
      project: ctx_value(ctx, :project),
      runtime_snapshot: ctx_value(ctx, :runtime_snapshot),
      tools_filter: :follow_up,
      tool_allowlist: [],
      skip_consolidation: true,
      skip_skills: true,
      metadata: %{
        "_advisor" => true,
        "parent_run_id" => ctx_value(ctx, :run_id),
        "parent_session_key" => ctx_value(ctx, :session_key),
        "advisor_profile" => profile.name,
        "started_at_ms" => started_at
      }
    ]
    |> maybe_put_opt(:llm_stream_client, ctx_value(ctx, :llm_stream_client))
    |> maybe_put_opt(:req_llm_stream_text_fun, ctx_value(ctx, :req_llm_stream_text_fun))
    |> maybe_put_opt(:llm_call_fun, ctx_value(ctx, :llm_call_fun))
  end

  defp observation_attrs(question, context_mode, context_window, profile, model_runtime) do
    %{
      "question_hash" => hash_text(question),
      "question_preview" => String.slice(question, 0, 160),
      "context_mode" => context_mode,
      "context_window" => context_window,
      "profile" => profile.name,
      "provider" => runtime_value(model_runtime, :provider) |> to_string(),
      "model" => runtime_value(model_runtime, :model_id) |> to_string()
    }
  end

  defp emit(level, tag, attrs, ctx) do
    opts =
      []
      |> maybe_put_opt(:workspace, workspace_from_ctx(ctx))
      |> maybe_put_opt(:run_id, ctx_value(ctx, :run_id))
      |> maybe_put_opt(:session_key, ctx_value(ctx, :session_key))
      |> maybe_put_opt(:channel, ctx_value(ctx, :channel))
      |> maybe_put_opt(:chat_id, ctx_value(ctx, :chat_id))
      |> maybe_put_opt(:tool_call_id, ctx_value(ctx, :tool_call_id))

    Log.emit(Atom.to_string(level), tag, attrs, opts, %{
      "module" => inspect(__MODULE__),
      "function" => "execute/2",
      "file" => __ENV__.file,
      "line" => __ENV__.line
    })
  rescue
    _ -> :ok
  end

  defp config_from_ctx(ctx) do
    case ctx_value(ctx, :runtime_snapshot) do
      %Snapshot{config: %Config{} = config} -> config
      _ -> ctx_value(ctx, :config)
    end
  end

  defp workspace_from_ctx(ctx) do
    ctx_value(ctx, :workspace) ||
      case ctx_value(ctx, :runtime_snapshot) do
        %Snapshot{workspace: workspace} -> workspace
        _ -> nil
      end
  end

  defp context_window(args, profile) do
    normalize_positive_integer(Map.get(args, "context_window")) ||
      profile.context_window ||
      @default_context_window
  end

  defp normalize_question(value) do
    case normalize_text(value) do
      nil -> {:error, "question is required"}
      question -> {:ok, question}
    end
  end

  defp normalize_context_mode(nil), do: {:ok, "recent"}

  defp normalize_context_mode(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      mode when mode in ["full", "recent", "none"] -> {:ok, mode}
      _ -> {:error, "context_mode must be one of full, recent, none"}
    end
  end

  defp normalize_context_mode(_value), do: {:error, "context_mode must be a string"}

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_positive_integer(_value), do: nil

  defp normalize_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_text(_value), do: nil

  defp profile_names(profiles) when is_map(profiles) do
    profiles
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp profile_names(_profiles), do: []

  defp include_default_advisor(names) do
    (["advisor"] ++ names)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp profile_schema([]) do
    %{
      type: "string",
      description: "Subagent profile to use for advisor instructions. Defaults to advisor."
    }
  end

  defp profile_schema(names) do
    %{
      type: "string",
      enum: names,
      description: "Subagent profile to use for advisor instructions. Defaults to advisor."
    }
  end

  defp truncate_context(text) do
    length = String.length(text)

    if length > @max_context_chars do
      start = length - @max_context_chars

      "[truncated to last #{@max_context_chars} chars]\n" <>
        String.slice(text, start, @max_context_chars)
    else
      text
    end
  end

  defp render_result(result) when is_binary(result), do: result
  defp render_result(nil), do: ""
  defp render_result(result), do: to_string(result)

  defp render_value(value) when is_binary(value), do: value
  defp render_value(nil), do: ""
  defp render_value(value), do: inspect(value, printable_limit: 1000, limit: 50)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason, printable_limit: 500, limit: 20)

  defp reason_type(reason) when is_binary(reason), do: "error"
  defp reason_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_type(_reason), do: "error"

  defp runtime_value(nil, _key), do: nil
  defp runtime_value(runtime, key) when is_map(runtime), do: Map.get(runtime, key)

  defp ctx_value(ctx, key) when is_map(ctx), do: Map.get(ctx, key) || Map.get(ctx, to_string(key))
  defp ctx_value(_ctx, _key), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp duration_since(started_at), do: System.monotonic_time(:millisecond) - started_at

  defp hash_text(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
  end

  defp call_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
