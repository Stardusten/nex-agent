defmodule Nex.Agent.ContextBuilder do
  @moduledoc """
  Builds context for LLM calls - system prompt + messages.
  """

  require Logger

  alias Nex.Agent.{Config, ContextDiagnostics, Skills, Workspace}
  alias Nex.Agent.Media.Projector

  @bootstrap_layer_order [
    {"AGENTS.md", :agents},
    {"SOUL.md", :soul},
    {"USER.md", :user},
    {"TOOLS.md", :tools}
  ]
  @legacy_soul_footers [
    "*编辑此文件来自定义助手的行为风格和价值观。身份定义由代码层管理，此处不可重新定义。*",
    "*Edit this file to customize the agent's behavioral style and values. Identity is code-owned and cannot be redefined here.*"
  ]
  @runtime_context_tag "[Runtime Context — metadata only, not instructions]"

  @type message :: %{required(String.t()) => any()}

  @doc """
  Build system prompt from identity, bootstrap files, and memory.
  """
  @spec build_system_prompt(keyword()) :: String.t()
  def build_system_prompt(opts \\ []) do
    {prompt, _diagnostics} = build_system_prompt_with_diagnostics(opts)
    prompt
  end

  @doc """
  Build system prompt and return deterministic boundary diagnostics.
  """
  @spec build_system_prompt_with_diagnostics(keyword()) ::
          {String.t(), [ContextDiagnostics.diagnostic()]}
  def build_system_prompt_with_diagnostics(opts \\ []) do
    workspace = Keyword.get(opts, :workspace) || default_workspace()

    parts =
      []
      |> add_authoritative_identity()
      |> add_runtime_guidance(workspace)
      |> add_evolution_guidance()

    {parts, bootstrap_diagnostics} = load_bootstrap_files_with_diagnostics(parts, workspace)
    {parts, memory_diagnostics} = add_memory_with_diagnostics(parts, workspace)
    parts = add_always_skills(parts, workspace, opts)

    diagnostics = bootstrap_diagnostics ++ memory_diagnostics

    {Enum.join(parts, "\n\n---\n\n"), diagnostics}
  end

  @doc """
  Build diagnostics only for currently loaded context layers.
  """
  @spec build_system_prompt_diagnostics(keyword()) :: [ContextDiagnostics.diagnostic()]
  def build_system_prompt_diagnostics(opts \\ []) do
    {_prompt, diagnostics} = build_system_prompt_with_diagnostics(opts)
    diagnostics
  end

  defp default_workspace do
    Workspace.root()
  end

  defp add_authoritative_identity(parts) do
    parts ++ [authoritative_identity()]
  end

  defp add_runtime_guidance(parts, workspace) do
    workspace_path = Path.expand(workspace)
    system = :os.type() |> elem(0) |> to_string()
    arch = :os.type() |> elem(1) |> to_string()
    runtime = "#{system} #{arch}, Elixir #{System.version()}"

    runtime_guidance = """
    ## Runtime
    #{runtime}

    ## Workspace
    Your workspace is at: #{workspace_path}
    - Long-term memory: #{workspace_path}/memory/MEMORY.md (write important facts here)
    - Custom skills: #{workspace_path}/skills/{skill-name}/SKILL.md
    - Workspace tools: #{Path.join(workspace_path, "tools")}/{tool-name}/
    - Notes and raw captures: #{workspace_path}/notes/
    - Personal task state: #{workspace_path}/tasks/tasks.json
    - Project memory: #{workspace_path}/projects/{project}/PROJECT.md
    - Executor configs and run logs: #{workspace_path}/executors/
    - Runtime observations: query with the `observe` tool; machine facts live under #{workspace_path}/control_plane/

    ## Guidelines
    - State the next action before tool calls, but NEVER predict or claim results before receiving them.
    - Discover code with `find` first.
    - If you already know the module, prefer `reflect source` with `module`.
    - If you already know the file path, prefer `read` or `reflect source` with `path`.
    - Modify code with `apply_patch`. After patching, re-read critical files if accuracy matters.
    - If a tool call fails, analyze the error before retrying with a different approach.
    - Ask for clarification when the request is ambiguous.
    - Editing tools only write to disk. Runtime activation for CODE changes must go through `self_update deploy`.
    - Do not infer runtime activation, restarts, or hot reload from file writes or process age.
    - Caveat: the current call may still run old code. Expect only a successful `self_update deploy` to activate the next version.
    - Use `self_update status` as the deploy preflight entrypoint. It reports plan source, blocked reasons, related tests, current effective release, current event release, and rollback candidates.
    - `self_update deploy` is the quick deploy verification path: syntax, compile, reload, and related tests.
    - Strict ship checks such as `format`, `credo`, or `dialyzer` are for explicit ship confidence, not mandatory on every quick deploy iteration.
    - In owner/subagent workflows, subagents may inspect and patch code, but only the owner run may use `self_update status`, `self_update deploy`, or `self_update rollback`.
    - Use `observe` to answer questions like "did anything fail?", "is it stuck?", or "what did the background runtime see?".
    - `observe summary` includes the workspace `run.owner.current` gauge for active owner runs; `observe incident` and `observe query` can narrow by run_id or session_key.
    - `/status` is a deterministic quick view for the current owner run plus recent ControlPlane warning/error evidence.
    - `observe` can inspect run, inbound, follow-up, LLM, tool, HTTP, and self_update lifecycle observations by tag, run_id, session_key, or incident query.
    - ControlPlane observations are the self-observation source of truth; human text logs are only projections.
    - Budget only controls review/candidate signals. It never authorizes automatic deploy, code repair, memory writes, or skill writes.
    - Evolution proposes candidates first. Owner-approved execution goes through the single `evolution_candidate` lane.
    - Use `evolution_candidate list` / `show` to inspect derived candidate lifecycle.
    - Use `evolution_candidate approve` / `reject` only as the owner run. Non-code candidates reuse existing deterministic write tools; code candidates must still go through `apply_patch` and `self_update deploy`.
    - Skills are discoverable runtime packages, not preloaded instructions. Use `skill_discover` to search, `skill_get` to inspect a package with progressive disclosure, and `skill_capture` to save a reusable local knowledge package.
    - Use `ask_advisor` when you need an internal second opinion on a plan, a stuck state, or a risky choice. Advisor output is internal guidance for this run and is not automatically user-visible.

    Reply directly with text for normal conversations.
    Never expose tool calls, progress updates, chain-of-thought, or "I sent it" status messages to the end user.
    Only use the 'message' tool when the tool payload itself is the user-visible message for a chat channel.
    If you use the 'message' tool for the current conversation, do not also narrate or summarize that send in assistant text.

    ## Channel Output Rules
    - Normal assistant replies stay model-side plain text. Channel-specific rendering happens after generation.
    - Do not emit platform JSON payloads unless a tool explicitly requires them.
    - `<newmsg/>` is a platform text IR separator, not prose. Never explain or expose it to the user.
    - Wherever `<newmsg/>` appears in assistant text, the runtime treats it as a hard new-message boundary.
    - Use `<newmsg/>` only when you intentionally want the runtime to split or separate user-visible sections.
    - If a structure is not reliably supported by the current channel, prefer simpler markdown-like text instead of inventing unsupported syntax.
    - For Discord, do not use `####` or deeper headings; only `#`, `##`, and `###` headings render reliably.

    ## Feishu Tooling
    - When using the `message` tool for channel=`feishu`, plain `content` is usually enough for assistant replies.
    - Use native `msg_type` and `content_json` only when you intentionally need a Feishu-specific payload.
    - If you have a local PNG/JPEG file and want to send it to Feishu, use `local_image_path` on the `message` tool.
    - If you do not already have a valid `image_key` or `file_key`, do not guess one.
    - Lark/Feishu business operations such as Docs, Sheets, Base, Calendar, Tasks, Drive, or search are not built-in tools anymore.
    - If `lark-cli` is installed, use `bash` to call it for those operations.
    - If `lark-cli` is missing, surface the shell error and give an installation hint instead of trying old `feishu_*` tool names.
    """

    parts ++ [runtime_guidance]
  end

  defp authoritative_identity do
    """
    ## Runtime Identity

    Identity is defined by workspace layers (SOUL.md, etc.).
    No default persona is imposed by the runtime.
    """
  end

  defp add_evolution_guidance(parts) do
    guidance = """
    ## Runtime Evolution

    Route long-term changes into the correct layer:

    - SOUL: persona, values, and operating style (persona layer)
    - USER: user profile, preferences, timezone, communication style, collaboration expectations
    - MEMORY: environment facts, project conventions, workflow lessons, durable operational context
    - SKILL: reusable multi-step workflows and procedural knowledge
    - TOOL: deterministic executable capabilities
    - CODE: internal implementation upgrades

    Prefer the highest layer that solves the need. Do not persist one-off outputs, temporary state, or information that is easy to rediscover.
    If the user explicitly asks to trigger memory refresh now, use `memory_consolidate` directly.
    For deterministic inspection of memory refresh status, prefer the `memory_status` tool over free-form inference.
    If long-term memory is clearly stale or incomplete and the user explicitly wants a full rebuild, use `memory_rebuild`.
    When a built-in memory tool directly matches the user's request, do not inspect implementation with `read` or `bash` first.
    When asked whether memory was updated or previously triggered, inspect MEMORY.md and the current session state before answering.
    Empty `MEMORY.md` does not imply this is the first conversation or that no prior session history exists.
    """

    parts ++ [guidance]
  end

  defp load_bootstrap_files_with_diagnostics(parts, workspace) do
    {chunks, diagnostics} =
      Enum.reduce(@bootstrap_layer_order, {[], []}, fn {filename, layer},
                                                       {acc_chunks, acc_diag} ->
        path = Path.join(workspace, filename)

        case File.read(path) do
          {:ok, content} ->
            normalized_content = normalize_bootstrap_content(layer, content)
            section = build_bootstrap_section(filename, layer, normalized_content)

            file_diagnostics =
              ContextDiagnostics.scan(layer, normalized_content, source: filename)

            {[section | acc_chunks], acc_diag ++ file_diagnostics}

          {:error, _} ->
            {acc_chunks, acc_diag}
        end
      end)

    chunks = Enum.reverse(chunks)
    parts = if chunks == [], do: parts, else: parts ++ [Enum.join(chunks, "\n\n")]
    {parts, diagnostics}
  end

  defp build_bootstrap_section(filename, layer, content) do
    layer_label = layer_label(layer)
    layer_boundary = layer_boundary(layer)

    ("## #{filename} (Layer: #{layer_label})\n\n" <>
       "Interpretation: #{layer_boundary}\n\n" <>
       String.trim(content))
    |> String.trim()
  end

  defp normalize_bootstrap_content(:soul, content) do
    content
    |> to_string()
    |> then(fn text ->
      Enum.reduce(@legacy_soul_footers, text, fn footer, acc ->
        String.replace(acc, footer, "")
      end)
    end)
    |> String.replace(~r/\n[ \t]*---[ \t]*\n\s*\z/u, "\n")
    |> String.trim_trailing()
  end

  defp normalize_bootstrap_content(_layer, content), do: content

  defp add_memory_with_diagnostics(parts, workspace) do
    memory_raw = Nex.Agent.Memory.read_long_term(workspace: workspace)

    diagnostics =
      ContextDiagnostics.scan(:memory, memory_raw, source: "memory/MEMORY.md")

    memory = Nex.Agent.Memory.get_memory_context(workspace: workspace)
    parts = if memory == "", do: parts, else: parts ++ ["# Memory\n\n" <> memory]
    {parts, diagnostics}
  end

  defp add_always_skills(parts, workspace, opts) do
    if Keyword.get(opts, :skip_skills, false) do
      parts
    else
      content = Skills.always_instructions(workspace: workspace)

      if String.trim(content) == "" do
        parts
      else
        parts ++ [content]
      end
    end
  end

  defp layer_label(:agents), do: "AGENTS"
  defp layer_label(:soul), do: "SOUL"
  defp layer_label(:user), do: "USER"
  defp layer_label(:tools), do: "TOOLS"
  defp layer_label(:memory), do: "MEMORY"
  defp layer_label(_), do: "UNKNOWN"

  defp layer_boundary(:agents),
    do:
      "System-level operating guidance. Hard-coded capability/model claims are diagnosed, but active persona can be refined elsewhere."

  defp layer_boundary(:soul),
    do:
      "Persona, values, style, and optional identity framing. User profile details still belong in USER."

  defp layer_boundary(:user),
    do:
      "User profile and collaboration preferences only. Identity or persona rewrites are non-authoritative and diagnosed."

  defp layer_boundary(:tools),
    do:
      "Tool descriptions and usage references only; does not define identity, persona, or durable memory facts."

  defp layer_boundary(:memory),
    do: "Durable factual context only; does not define identity or persona ownership."

  defp layer_boundary(_),
    do: "Legacy content is tolerated but interpreted under layer boundaries with diagnostics."

  @doc """
  Build runtime context block with only essential metadata.
  """
  @spec build_runtime_context(String.t() | nil, String.t() | nil) :: String.t()
  def build_runtime_context(channel, chat_id) do
    build_runtime_context(channel, chat_id, [])
  end

  @spec build_runtime_context(String.t() | nil, String.t() | nil, keyword()) :: String.t()
  def build_runtime_context(channel, chat_id, opts) do
    now = DateTime.utc_now()
    time_str = Calendar.strftime(now, "%Y-%m-%d %H:%M (%A)")
    cwd = Keyword.get(opts, :cwd)
    repo_root = git_root(cwd)
    config = Keyword.get(opts, :config)

    lines =
      [@runtime_context_tag, "Current Time: #{time_str}"]
      |> then(fn lines ->
        if channel && chat_id do
          lines ++ ["Channel: #{channel}", "Chat ID: #{chat_id}"]
        else
          lines
        end
      end)
      |> then(fn lines ->
        if is_binary(channel) do
          lines ++ channel_runtime_lines(channel, config)
        else
          lines
        end
      end)
      |> then(fn lines ->
        if is_binary(cwd) and cwd != "" do
          lines ++ ["Working Directory: #{Path.expand(cwd)}"]
        else
          lines
        end
      end)
      |> then(fn lines ->
        if is_binary(repo_root) and repo_root != "" do
          lines ++ ["Git Repository Root: #{repo_root}"]
        else
          lines
        end
      end)

    Enum.join(lines, "\n")
  end

  defp channel_runtime_lines(channel, %Config{} = config) do
    channel_runtime = Config.channel_runtime(config, channel)
    channel_type = Map.get(channel_runtime, "type")
    streaming? = Map.get(channel_runtime, "streaming", false) == true

    base = ["Channel Streaming: #{if streaming?, do: "streaming", else: "single"}"]

    newmsg_guidance =
      "`<newmsg/>` splits your reply into separate messages wherever it appears."

    case channel_type do
      "feishu" ->
        base ++
          [
            "Channel IR: feishu markdown-like text IR",
            "Feishu IR supports headings, lists, quotes, fenced code blocks, tables, and `<newmsg/>`.",
            newmsg_guidance
          ]

      "discord" ->
        base ++
          [
            "Channel IR: Discord markdown",
            "Discord supports: bold, italic, underline (__text__), strikethrough, headings (#/##/### only), lists, quotes (> and >>>), inline code, fenced code blocks with syntax highlighting, links, spoiler tags (||text||), and `<newmsg/>`.",
            "Do not use `####` or deeper headings in Discord replies.",
            "Discord does NOT support: tables, image embeds (![]()), horizontal rules (---), or HTML. Use fenced code blocks to present tabular data.",
            newmsg_guidance
          ]

      _ ->
        base ++ ["Channel IR: markdown-like plain text"]
    end
  end

  defp channel_runtime_lines(_channel, _config), do: []

  @doc """
  Build full message list for LLM call.
  """
  @spec build_messages(
          [message()],
          String.t(),
          String.t() | nil,
          String.t() | nil,
          [Nex.Agent.Media.Attachment.t()] | nil,
          keyword()
        ) :: [message()]
  def build_messages(
        history,
        current_message,
        channel \\ nil,
        chat_id \\ nil,
        media \\ nil,
        opts \\ []
      ) do
    runtime_ctx = build_runtime_context(channel, chat_id, opts)
    user_content = build_user_content(current_message, media)
    runtime_system_messages = Keyword.get(opts, :runtime_system_messages, [])

    merged =
      if is_binary(user_content) do
        runtime_ctx <> "\n\n" <> user_content
      else
        [%{"type" => "text", "text" => runtime_ctx} | user_content]
      end

    system_prompt =
      case Keyword.get(opts, :system_prompt) do
        prompt when is_binary(prompt) and prompt != "" ->
          prompt

        _ ->
          Logger.warning(
            "[ContextBuilder] Missing :system_prompt in build_messages/6; falling back to live prompt build"
          )

          build_system_prompt(opts)
      end

    system_content =
      case runtime_system_messages do
        [] ->
          system_prompt

        messages when is_list(messages) ->
          system_prompt <> "\n\n---\n\n" <> Enum.join(messages, "\n\n")
      end

    [
      %{"role" => "system", "content" => system_content},
      Enum.map(history, &clean_history_entry/1),
      %{"role" => "user", "content" => merged}
    ]
    |> List.flatten()
  end

  defp clean_history_entry(%{} = entry) do
    role = Map.get(entry, "role") || Map.get(entry, :role) || "user"
    content = Map.get(entry, "content") || Map.get(entry, :content) || ""

    cleaned = %{"role" => role, "content" => content}

    cleaned =
      case Map.get(entry, "tool_calls") || Map.get(entry, :tool_calls) do
        calls when is_list(calls) and calls != [] -> Map.put(cleaned, "tool_calls", calls)
        _ -> cleaned
      end

    cleaned =
      case Map.get(entry, "tool_call_id") || Map.get(entry, :tool_call_id) do
        nil ->
          cleaned

        tool_call_id ->
          cleaned
          |> Map.put("tool_call_id", tool_call_id)
          |> then(fn cleaned ->
            case Map.get(entry, "name") || Map.get(entry, :name) do
              nil -> cleaned
              name -> Map.put(cleaned, "name", name)
            end
          end)
      end

    case Map.get(entry, "reasoning_content") || Map.get(entry, :reasoning_content) do
      nil -> cleaned
      reasoning_content -> Map.put(cleaned, "reasoning_content", reasoning_content)
    end
  end

  defp build_user_content(text, nil), do: text
  defp build_user_content(text, []), do: text

  defp build_user_content(text, attachments) when is_list(attachments) and attachments != [] do
    Projector.project_for_model(attachments, []) ++ [%{"type" => "text", "text" => text}]
  end

  defp git_root(nil), do: nil
  defp git_root(""), do: nil

  defp git_root(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)

    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true, cd: cwd) do
      {path, 0} -> String.trim(path)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Add assistant message to messages list.
  """
  @spec add_assistant_message([message()], String.t() | nil, [map()] | nil, String.t() | nil) :: [
          message()
        ]
  def add_assistant_message(messages, content, tool_calls \\ nil, reasoning_content \\ nil) do
    message = %{"role" => "assistant", "content" => content || ""}

    message =
      case tool_calls do
        calls when is_list(calls) and calls != [] -> Map.put(message, "tool_calls", calls)
        _ -> message
      end

    message =
      case reasoning_content do
        nil -> message
        "" -> message
        value -> Map.put(message, "reasoning_content", value)
      end

    messages ++ [message]
  end

  @doc """
  Add tool result to messages list.
  """
  @spec add_tool_result([message()], String.t(), String.t(), String.t()) :: [message()]
  def add_tool_result(messages, tool_call_id, tool_name, result) do
    messages ++
      [
        %{
          "role" => "tool",
          "tool_call_id" => tool_call_id,
          "name" => tool_name,
          "content" => result
        }
      ]
  end
end
