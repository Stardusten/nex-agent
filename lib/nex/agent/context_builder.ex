defmodule Nex.Agent.ContextBuilder do
  @moduledoc """
  Builds context for LLM calls - system prompt + messages.
  """

  require Logger

  alias Nex.Agent.{Config, ContextDiagnostics, Skills, Workspace}
  alias Nex.Agent.Media.Projector

  @bootstrap_layer_order [
    {"AGENTS.md", :agents},
    {"IDENTITY.md", :identity},
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
    parts = add_skill_catalog(parts, workspace, opts)

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
    - Identity: #{workspace_path}/IDENTITY.md (durable self-model)
    - Long-term memory: #{workspace_path}/memory/MEMORY.md (write important facts here)
    - Custom skills: #{workspace_path}/skills/{skill-name}/SKILL.md
    - Workspace tools: #{Path.join(workspace_path, "tools")}/{tool-name}/
    - Notes and raw captures: #{workspace_path}/notes/
    - Personal task state: #{workspace_path}/tasks/tasks.json
    - Project memory: #{workspace_path}/projects/{project}/PROJECT.md
    - Executor configs and run logs: #{workspace_path}/executors/
    - Runtime observations: query with the `observe` tool; machine facts live under #{workspace_path}/control_plane/

    ## Runtime Capability Map
    - You are a long-running NexAgent personal agent runtime instance, not a one-off chatbot or a generic CLI wrapper.
    - Chat channels are user-facing surfaces. The durable working state lives in workspace, sessions, memory, skills, tools, ControlPlane, Workbench, and CODE self-update paths.
    - You can use deterministic tools, load skills on demand, maintain durable memory/skills, inspect runtime observations, author Workbench apps, and modify framework CODE through the self-update lane.
    - Workbench is the built-in local web UI and app host. When enabled with default config, its local URL is `http://127.0.0.1:50051/workbench`.
    - Workbench apps are optional iframe artifacts under `workspace/workbench/apps/`; an empty app directory does not mean the Workbench Server is absent.

    ## Guidelines
    - State the next action before tool calls, but NEVER predict or claim results before receiving them.
    - Discover code with `find` first.
    - If you already know the module, prefer `reflect source` with `module`.
    - If you already know the file path, prefer `read` or `reflect source` with `path`.
    - Modify code with `apply_patch`. After patching, re-read critical files if accuracy matters.
    - If a tool call fails, analyze the error before retrying with a different approach.
    - Ask for clarification when the request is ambiguous.
    - Skill cards are listed in this prompt as lightweight availability metadata. When a card matches the task, call `skill_get` with its `id` to load the full skill before following it.
    - Use `skill_capture` to save a reusable local Markdown skill when a workflow should become durable SKILL-layer knowledge.
    - Use `ask_advisor` when you need an internal second opinion on a plan, a stuck state, or a risky choice. Advisor output is internal guidance for this run and is not automatically user-visible.

    ## Scenario Skills
    Load the relevant built-in skill before acting on these low-frequency workflows:
    - `builtin:nex-code-maintenance`: framework CODE edits, runtime activation, deploy/rollback, ReqLLM/provider adapter work, and CODE-layer tests.
    - `builtin:runtime-observability`: runtime status, failures, stuck runs, logs, incidents, ControlPlane observations, budgets, gauges, owner runs, and background task evidence.
    - `builtin:memory-and-evolution-routing`: memory refresh/status/rebuild, durable memory writes, user corrections, layer routing, and self-improvement/evolution candidates.
    - `builtin:lark-feishu-ops`: Feishu/Lark native payloads, media sends, business operations, `lark-cli`, and Feishu-specific troubleshooting.
    - `builtin:workbench-app-authoring`: creating or modifying Workbench apps, app manifests, iframe assets, static app artifacts, and app-local `reload.sh`.

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
    - For Feishu/Lark business operations or troubleshooting, load `builtin:lark-feishu-ops` before acting.
    """

    parts ++ [runtime_guidance]
  end

  defp authoritative_identity do
    """
    ## Runtime Identity

    Identity is defined by workspace layers (IDENTITY.md, SOUL.md, etc.).
    No default persona is imposed by the runtime.
    """
  end

  defp add_evolution_guidance(parts) do
    guidance = """
    ## Runtime Evolution

    Route long-term changes into the correct layer:

    - IDENTITY: durable self-model, boundaries, and product/runtime relationship
    - SOUL: persona, values, and operating style (persona layer)
    - USER: user profile, preferences, timezone, communication style, collaboration expectations
    - MEMORY: environment facts, project conventions, workflow lessons, durable operational context
    - SKILL: reusable multi-step workflows and procedural knowledge
    - TOOL: deterministic executable capabilities
    - CODE: internal implementation upgrades

    Prefer the highest layer that solves the need. Do not persist one-off outputs, temporary state, or information that is easy to rediscover.
    For memory refresh/status/rebuild, durable corrections, and evolution candidate routing, load `builtin:memory-and-evolution-routing` before acting.
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

  defp add_skill_catalog(parts, workspace, opts) do
    if Keyword.get(opts, :skip_skills, false) do
      parts
    else
      content =
        case Keyword.get(opts, :skill_catalog_prompt) do
          content when is_binary(content) ->
            content

          _ ->
            Skills.catalog_prompt(
              workspace: workspace,
              project_root: Keyword.get(opts, :project_root) || Keyword.get(opts, :cwd)
            )
        end

      if String.trim(content) == "" do
        parts
      else
        parts ++ [content]
      end
    end
  end

  defp layer_label(:agents), do: "AGENTS"
  defp layer_label(:identity), do: "IDENTITY"
  defp layer_label(:soul), do: "SOUL"
  defp layer_label(:user), do: "USER"
  defp layer_label(:tools), do: "TOOLS"
  defp layer_label(:memory), do: "MEMORY"
  defp layer_label(_), do: "UNKNOWN"

  defp layer_boundary(:agents),
    do:
      "System-level operating guidance. Hard-coded capability/model claims are diagnosed; durable self-definition belongs in IDENTITY."

  defp layer_boundary(:identity),
    do:
      "Durable agent self-model: what the agent is, is not, and how to discuss its runtime/product identity."

  defp layer_boundary(:soul),
    do:
      "Persona, values, voice, and operating style. Core self-definition belongs in IDENTITY; user profile details belong in USER."

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
    parent_chat_id = Keyword.get(opts, :parent_chat_id)

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
        if present?(parent_chat_id) do
          lines ++ ["Chat Scope ID (parent_chat_id): #{parent_chat_id}"]
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

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp channel_runtime_lines(channel, %Config{} = config) do
    channel_runtime = Config.channel_runtime(config, channel)
    channel_type = Map.get(channel_runtime, "type")
    streaming? = Map.get(channel_runtime, "streaming", false) == true
    show_table_as = Map.get(channel_runtime, "show_table_as", "ascii")

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
            "Discord format guide: use paragraphs, bullets, short headings, blockquotes, and bold for emphasis; reserve fenced code blocks for code, logs, config, or table-like data.",
            "Do not use `####` or deeper headings, and do not wrap plain emphasis or short concept contrasts in fenced `text` blocks.",
            "Discord does NOT support image embeds (![]()), horizontal rules (---), or HTML. Markdown tables render as #{show_table_as} (raw/ascii/embed channel setting).",
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
      |> append_context_hook_fragments(Keyword.get(opts, :context_hook_fragments, []))

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

  defp append_context_hook_fragments(system_prompt, fragments) when is_list(fragments) do
    rendered =
      fragments
      |> Enum.map(&render_context_hook_fragment/1)
      |> Enum.reject(&(&1 == ""))

    if rendered == [] do
      system_prompt
    else
      system_prompt <> "\n\n---\n\n" <> Enum.join(rendered, "\n\n---\n\n")
    end
  end

  defp append_context_hook_fragments(system_prompt, _fragments), do: system_prompt

  defp render_context_hook_fragment(%{} = fragment) do
    title = Map.get(fragment, "title") || Map.get(fragment, :title) || "Context Hook"
    id = Map.get(fragment, "id") || Map.get(fragment, :id) || "-"
    source = Map.get(fragment, "source") || Map.get(fragment, :source) || "-"
    hash = Map.get(fragment, "hash") || Map.get(fragment, :hash) || "-"
    chars = Map.get(fragment, "chars") || Map.get(fragment, :chars) || 0
    raw_chars = Map.get(fragment, "raw_chars") || Map.get(fragment, :raw_chars) || chars
    truncated? = Map.get(fragment, "truncated") || Map.get(fragment, :truncated) || false
    content = Map.get(fragment, "content") || Map.get(fragment, :content) || ""

    truncation_line =
      if truncated? do
        "\nTruncated: true (#{chars}/#{raw_chars} chars injected)"
      else
        ""
      end

    [
      "## Context Hook: #{title}",
      "",
      "Hook ID: #{id}",
      "Source: #{source}",
      "Content SHA256: #{hash}",
      "Chars: #{chars}#{truncation_line}",
      "",
      to_string(content)
    ]
    |> Enum.join("\n")
  end

  defp render_context_hook_fragment(_fragment), do: ""

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
