defmodule Nex.Agent.App.Onboarding do
  @moduledoc """
  Automatically initializes the system by creating directories and workspace templates on first run.
  """

  alias Nex.Agent.{Runtime.Config, Runtime.Workspace}

  require Logger

  @default_base_dir Path.join(System.get_env("HOME", "~"), ".nex/agent")
  @agents_managed_key "AGENTS_MANAGED_V1"
  @tools_managed_key "TOOLS_MANAGED_V1"

  defp base_dir do
    Application.get_env(:nex_agent, :agent_base_dir, @default_base_dir)
  end

  @doc """
  Ensure the system is initialized. On first run, create directories and config.
  """
  @spec ensure_initialized() :: :ok
  def ensure_initialized do
    unless File.exists?(Config.config_path()) do
      init_directories()
      Config.save(Config.set(Config.default(), :default_workspace, Workspace.root()))
    end

    maybe_migrate_legacy()
    init_workspace_templates()
    :ok
  end

  @doc """
  Ensure an arbitrary workspace has the runtime directories and template files.
  """
  @spec ensure_workspace_initialized(String.t()) :: :ok
  def ensure_workspace_initialized(workspace) when is_binary(workspace) do
    Workspace.ensure!(workspace: workspace)
    File.mkdir_p!(Path.join(workspace, "sessions"))
    init_workspace_templates(workspace)
    :ok
  end

  @doc """
  Check whether initialization has already happened.
  """
  @spec initialized?() :: boolean()
  def initialized? do
    File.exists?(Config.config_path())
  end

  @doc """
  Force reinitialization, typically for upgrades or repairs.
  """
  @spec reinitialize() :: :ok
  def reinitialize do
    File.rm(Config.config_path())
    ensure_initialized()
  end

  defp init_directories do
    w = Workspace.root()

    dirs = [
      base_dir(),
      Path.join(w, "sessions")
    ]

    Enum.each(dirs, &File.mkdir_p!/1)
    Workspace.ensure!(workspace: w)
    init_workspace_templates(w)
  end

  defp maybe_migrate_legacy do
    b = base_dir()
    w = Workspace.root()

    migrate_legacy_dir(Path.join(b, "skills"), Path.join(w, "skills"), "skills")
    migrate_legacy_dir(Path.join(b, "sessions"), Path.join(w, "sessions"), "sessions")
    migrate_legacy_dir(Path.join(b, "tools"), Path.join(w, "tools"), "tools")

    migrate_legacy_cron_jobs(
      Path.join([b, "cron", "jobs.json"]),
      Path.join([w, "tasks", "cron_jobs.json"])
    )

    # Clean up legacy artifacts
    legacy_paths = [
      Path.join(b, "evolution"),
      Path.join(b, ".initialized"),
      Path.join(b, "cron")
    ]

    Enum.each(legacy_paths, fn path ->
      if File.exists?(path) do
        File.rm_rf!(path)
        Logger.info("[Onboarding] Removed legacy: #{path}")
      end
    end)
  end

  defp migrate_legacy_dir(old_dir, new_dir, label) do
    if File.exists?(old_dir) do
      File.mkdir_p!(new_dir)

      old_dir
      |> File.ls!()
      |> Enum.each(fn entry ->
        source = Path.join(old_dir, entry)
        destination = Path.join(new_dir, entry)

        unless File.exists?(destination) do
          File.rename(source, destination)
        end
      end)

      File.rm_rf!(old_dir)
      Logger.info("[Onboarding] Migrated #{label}/ to workspace/#{label}/")
    end
  end

  defp migrate_legacy_cron_jobs(old_file, new_file) do
    cond do
      not File.exists?(old_file) ->
        :ok

      not File.exists?(new_file) ->
        File.mkdir_p!(Path.dirname(new_file))
        File.rename(old_file, new_file)
        Logger.info("[Onboarding] Migrated cron jobs to workspace/tasks/cron_jobs.json")

      true ->
        case merge_json_arrays(old_file, new_file, &cron_job_merge_key/1) do
          :ok ->
            File.rm_rf!(old_file)

            Logger.info(
              "[Onboarding] Merged legacy cron jobs into workspace/tasks/cron_jobs.json"
            )

          {:error, reason} ->
            Logger.warning("[Onboarding] Failed to migrate legacy cron jobs: #{inspect(reason)}")
        end
    end
  end

  defp merge_json_arrays(source_file, target_file, key_fun) do
    with {:ok, source_entries} <- read_json_array(source_file),
         {:ok, target_entries} <- read_json_array(target_file) do
      merged =
        target_entries ++
          Enum.reject(source_entries, fn entry ->
            source_key = key_fun.(entry)
            Enum.any?(target_entries, &(key_fun.(&1) == source_key))
          end)

      File.write!(target_file, Jason.encode!(merged, pretty: true))
      :ok
    end
  end

  defp read_json_array(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, entries} when is_list(entries) -> {:ok, entries}
          {:ok, _} -> {:error, :invalid_json_array}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cron_job_merge_key(entry) when is_map(entry) do
    Map.get(entry, "name") || Map.get(entry, :name) || Map.get(entry, "id") || Map.get(entry, :id)
  end

  defp init_workspace_templates do
    init_workspace_templates(Workspace.root())
  end

  defp init_workspace_templates(workspace) do
    w = workspace
    Workspace.ensure!(workspace: w)
    File.mkdir_p!(Path.join(w, "sessions"))

    managed_templates = [
      {Path.join(w, "AGENTS.md"), @agents_managed_key, agents_template()},
      {Path.join(w, "TOOLS.md"), @tools_managed_key, tools_template()}
    ]

    templates = [
      {Path.join(w, "IDENTITY.md"), identity_template()},
      {Path.join(w, "SOUL.md"), soul_template()},
      {Path.join(w, "USER.md"), user_template()},
      {Path.join(w, "memory/MEMORY.md"), memory_template()},
      {Path.join(w, "memory/HISTORY.md"), history_template()}
    ]

    Enum.each(managed_templates, fn {path, key, content} ->
      merge_managed_template(path, key, content)
    end)

    Enum.each(templates, fn {path, content} ->
      unless File.exists?(path) do
        File.write!(path, content)
      end
    end)

    normalize_workspace_cron_jobs(Path.join([w, "tasks", "cron_jobs.json"]))
    init_executor_templates(w)
    init_bundled_skills(w)
  end

  defp normalize_workspace_cron_jobs(path) do
    case read_json_array(path) do
      {:ok, entries} ->
        normalized = Enum.map(entries, &normalize_cron_job/1)

        if normalized != entries do
          File.write!(path, Jason.encode!(normalized, pretty: true))

          Logger.info(
            "[Onboarding] Normalized legacy cron jobs in workspace/tasks/cron_jobs.json"
          )
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Onboarding] Failed to normalize workspace cron jobs: #{inspect(reason)}")
    end
  end

  defp normalize_cron_job(entry) when is_map(entry) do
    case legacy_summary_scope(entry) do
      nil -> entry
      scope -> Map.put(entry, "message", legacy_summary_message(scope))
    end
  end

  defp legacy_summary_message("daily") do
    """
    Create a daily personal summary. Use the `task` tool with action=`summary` and scope=`daily`, then send the user a concise end-of-day update only if there is something useful to report.
    """
    |> String.trim()
  end

  defp legacy_summary_message("weekly") do
    """
    Create a weekly personal summary. Use the `task` tool with action=`summary` and scope=`weekly`, then send the user a concise weekly review with priorities and follow-ups.
    """
    |> String.trim()
  end

  defp legacy_summary_scope(entry) do
    name = Map.get(entry, "name", "") |> to_string()
    message = Map.get(entry, "message", "") |> to_string() |> String.trim()
    expr = get_in(entry, ["schedule", "expr"]) |> to_string()

    cond do
      not legacy_summary_job?(name, message) ->
        nil

      String.contains?(name, "weekly-summary") or expr == "0 9 * * 1" ->
        "weekly"

      String.contains?(name, "daily-summary") or expr == "0 21 * * *" ->
        "daily"

      true ->
        "daily"
    end
  end

  defp legacy_summary_job?(name, message) do
    message == "legacy summary" or
      (String.starts_with?(name, "legacy-") and String.contains?(name, "summary"))
  end

  defp init_executor_templates(workspace) do
    executors_dir = Path.join(workspace, "executors")
    File.mkdir_p!(executors_dir)

    templates = [
      {Path.join(executors_dir, "codex_cli.json"),
       %{
         "enabled" => false,
         "command" => "codex",
         "args" => [],
         "prompt_mode" => "stdin",
         "timeout" => 300
       }},
      {Path.join(executors_dir, "claude_code_cli.json"),
       %{
         "enabled" => false,
         "command" => "claude",
         "args" => [],
         "prompt_mode" => "stdin",
         "timeout" => 300
       }}
    ]

    Enum.each(templates, fn {path, content} ->
      unless File.exists?(path) do
        File.write!(path, Jason.encode!(content, pretty: true))
      end
    end)
  end

  defp merge_managed_template(path, key, content) do
    begin_marker = "<!-- BEGIN NEX:#{key} -->"
    end_marker = "<!-- END NEX:#{key} -->"
    managed_block = [begin_marker, String.trim(content), end_marker] |> Enum.join("\n")

    merged =
      case File.read(path) do
        {:ok, existing} ->
          if String.contains?(existing, begin_marker) and String.contains?(existing, end_marker) do
            pattern = ~r/#{Regex.escape(begin_marker)}[\s\S]*?#{Regex.escape(end_marker)}\n?/
            Regex.replace(pattern, existing, managed_block)
          else
            String.trim_trailing(existing) <> "\n\n" <> managed_block <> "\n"
          end

        {:error, _} ->
          managed_block <> "\n"
      end

    File.write!(path, merged)
  end

  defp init_bundled_skills(workspace) do
    skills_dir = Path.join(workspace, "skills")
    File.mkdir_p!(skills_dir)
    cleanup_legacy_bundled_skills(skills_dir)

    bundled_skills_dir()
    |> File.ls!()
    |> Enum.each(fn skill_name ->
      source_dir = Path.join(bundled_skills_dir(), skill_name)
      target_dir = Path.join(skills_dir, skill_name)

      if File.dir?(source_dir) and File.exists?(Path.join(source_dir, "SKILL.md")) do
        install_bundled_skill(source_dir, target_dir)
      end
    end)
  end

  defp cleanup_legacy_bundled_skills(skills_dir) do
    ["find-skills", "browser-mcp"]
    |> Enum.each(fn skill_name ->
      legacy_dir = Path.join(skills_dir, skill_name)

      if File.exists?(legacy_dir) do
        File.rm_rf!(legacy_dir)
        Logger.info("[Onboarding] Removed legacy bundled skill: #{skill_name}")
      end
    end)
  end

  defp bundled_skills_dir do
    case :code.priv_dir(:nex_agent) do
      path when is_list(path) ->
        Path.join(to_string(path), "skills")

      _ ->
        Path.expand("priv/skills")
    end
  end

  defp install_bundled_skill(source_dir, target_dir) do
    skill_name = Path.basename(source_dir)
    target_exists = File.exists?(target_dir)

    copy_missing_tree(source_dir, target_dir)

    unless target_exists do
      Logger.info("[Onboarding] Installed bundled skill: #{skill_name}")
    end
  end

  defp copy_missing_tree(source, target) do
    cond do
      File.dir?(source) ->
        File.mkdir_p!(target)

        source
        |> File.ls!()
        |> Enum.each(fn entry ->
          copy_missing_tree(Path.join(source, entry), Path.join(target, entry))
        end)

      File.exists?(target) ->
        :ok

      true ->
        File.mkdir_p!(Path.dirname(target))
        File.cp!(source, target)
    end
  end

  defp agents_template do
    """
    # AGENTS

    System-level instructions loaded into the model context each run.

    ## Workspace

    - Workspace root: `~/.nex/agent/workspace`
    - Identity: `workspace/IDENTITY.md`
    - Memory: `workspace/memory/MEMORY.md`
    - Skills: `workspace/skills/<name>/SKILL.md`
    - Workspace tools: `workspace/tools/<name>/`
    - Notes and captures: `workspace/notes/`
    - Personal tasks: `workspace/tasks/tasks.json`
    - Project memory: `workspace/projects/<project>/PROJECT.md`
    - Executor configs and logs: `workspace/executors/`
    - Runtime observations: query with `observe`; machine facts live under `workspace/control_plane/`
    - Sessions: `workspace/sessions/`

    ## Runtime Capability Map

    - I am a long-running NexAgent personal agent runtime instance, not a one-off chatbot or a generic CLI wrapper.
    - Chat channels are user-facing surfaces; durable working state lives in workspace, sessions, memory, skills, tools, ControlPlane, Workbench, and CODE self-update paths.
    - I can use deterministic tools, load skills on demand, maintain durable memory/skills, inspect runtime observations, author Workbench apps, and modify framework CODE through the self-update lane.
    - Workbench is the built-in local web UI and app host. When enabled with default config, its local URL is `http://127.0.0.1:50051/workbench`.
    - Workbench apps are optional iframe artifacts under `workspace/workbench/apps/`; an empty app directory does not mean the Workbench Server is absent.

    ## Prompt Composition

    The runtime system prompt is assembled from:

    1. Default runtime identity and runtime guidance
    2. Bootstrap files (`AGENTS.md`, `IDENTITY.md`, `SOUL.md`, `USER.md`, `TOOLS.md`)
    3. Long-term memory context
    4. On-demand skill discovery guidance

    Keep this file concise, stable, and system-level.

    ## Concept Discipline

    - Before answering architecture or product questions, classify each concept as a runtime/product, workflow/method, project/workspace, tool/surface, or durable state layer.
    - Do not conflate a runtime with a workflow it can maintain. OpenClaw is not Karpathy's knowledge base; OpenClaw, Claude Code, and NexAgent can be agent entry points for maintaining a Karpathy-style knowledge base.
    - For uncertain external product behavior, browse official sources or state uncertainty. Do not fill gaps with confident-sounding guesses.
    - For daily-use questions, start with the product-level mental model before proposing source-code audits.
    - Treat user corrections about self-model, product concepts, or workflow assumptions as self-improvement signals. Route them to the right layer: IDENTITY, SOUL, USER, MEMORY, SKILL, prompt rules, TOOL, or CODE.

    ## Operating Rules

    - State the next action before tool calls.
    - Never claim tool results before receiving actual outputs.
    - Discover code with `find` first.
    - If you know the module, prefer `reflect source`.
    - If you know the path, prefer `read` or `reflect source` with `path`.
    - Modify files with `apply_patch`, then re-read critical results when accuracy matters.
    - If tool calls fail, analyze and retry with a different approach.
    - Ask clarifying questions only when ambiguity blocks safe execution.
    - File edits only change disk state. CODE runtime activation goes through `self_update`; load `builtin:nex-code-maintenance` for the deploy workflow.
    - Use `skill_get` with a listed skill id before following long, low-frequency workflow guidance.
    - Test hygiene: use isolated temp directories and clean them in `on_exit`; do not leave persistent artifacts under `~/.nex/agent` from tests.

    ## Scenario Skills

    Load these built-in skills on demand with `skill_get`; their bodies are not meant to live permanently in AGENTS.md.

    - `builtin:nex-code-maintenance`: framework CODE edits, runtime activation, deploy/rollback, ReqLLM/provider work, and CODE-layer tests.
    - `builtin:runtime-observability`: runtime status, failures, stuck runs, incidents, ControlPlane evidence, budgets, gauges, owner runs, and background tasks.
    - `builtin:memory-and-evolution-routing`: memory refresh/status/rebuild, durable corrections, layer routing, and self-improvement/evolution candidates.
    - `builtin:lark-feishu-ops`: Feishu/Lark native payloads, media sends, `lark-cli`, business operations, and Feishu-specific troubleshooting.
    - `builtin:workbench-app-authoring`: Workbench apps, manifests, iframe assets, static app artifacts, permissions, and app-local `reload.sh`.

    ## Six-Layer Evolution

    - IDENTITY: durable self-model, boundaries, and product/runtime relationship
    - SOUL: values, personality, and long-term operating principles (persona layer)
    - USER: user profile and collaboration preferences
    - MEMORY: long-term facts about environment and project context
    - SKILL: reusable workflows and procedural knowledge
    - TOOL: deterministic executable capabilities
    - CODE: internal implementation upgrades

    ## Safety

    - Keep changes small, testable, and reversible.
    - Respect security boundaries; do not execute dangerous shell patterns.
    - Preserve evidence: report what was changed and what was verified.
    """
  end

  defp identity_template do
    """
    # Identity

    Durable self-model for this NexAgent instance.

    ## What I Am

    - I am a long-lived NexAgent personal agent instance.
    - I operate through chat channels, but channels are only surfaces.
    - My durable working semantics live in workspace, session, memory, tools, skills, ControlPlane, and self-update paths.
    - I treat the workspace as my active home/context for ongoing collaboration, not as a temporary execution directory.

    ## What I Am Not

    - I am not a one-off chatbot.
    - I am not merely a coding CLI.
    - I am not Karpathy's knowledge base, though I can help maintain a Karpathy-style knowledge base.
    - I should not claim to be OpenClaw or equivalent to OpenClaw without evidence.

    ## Product Relationship

    - NexAgent is this project's long-running personal agent runtime.
    - OpenClaw is a related product category/reference point: personal agent runtime, gateway, workspace, memory, sessions, tools, and channels.
    - The accurate self-description is: a NexAgent runtime instance evolving toward an OpenClaw-like personal agent system.

    ## Concept Discipline

    - Distinguish runtime/product, workflow/method, project/workspace, tool/surface, and durable state layer before making architecture claims.
    - Treat user corrections about self-model, product concepts, or workflow assumptions as self-improvement signals.
    - Route durable corrections to the right layer: IDENTITY, SOUL, USER, MEMORY, SKILL, prompt rules, TOOL, or CODE.
    """
  end

  defp tools_template do
    """
    # TOOLS

    Tool reference for the runtime prompt.

    ## Built-in Tool Families

    - Code/file workflow: `find`, `read`, `apply_patch`
    - Shell and execution: `bash`
    - Communication: `message`
    - Web and retrieval: `web_search`, `web_fetch`
    - Media generation: `image_generation`
    - Scheduling and background work: `cron`, `spawn_task`, `task`
    - Knowledge capture: `knowledge_capture`
    - Coding executor orchestration: `executor_dispatch`, `executor_status`
    - SOUL layer: `soul_update`
    - USER layer: `user_update`
    - MEMORY layer: `memory_consolidate`, `memory_status`, `memory_rebuild`, `memory_write`
    - SKILL layer: `skill_get`, `skill_capture`
    - TOOL layer: `tool_list`, `tool_create`, `tool_delete`
    - CODE layer: `reflect`, `self_update`

    ## Usage Principles

    - Prefer deterministic tools over free-form reasoning when possible.
    - Use the smallest tool that can solve the task.
    - Validate tool outputs before taking follow-up actions.
    - Load `builtin:nex-code-maintenance` before CODE deploy/rollback/provider work.
    - Load `builtin:runtime-observability` before answering runtime status, failure, stuck-run, log, incident, budget, gauge, owner-run, or background-task questions.
    - Load `builtin:memory-and-evolution-routing` before memory refresh/status/rebuild, durable correction, layer routing, or evolution-candidate work.
    - Load `builtin:lark-feishu-ops` before Feishu/Lark native payload, media, business operation, or `lark-cli` work.
    - Load `builtin:workbench-app-authoring` before creating or modifying Workbench apps.

    ## Workspace Extension Model

    - Workspace tools are Elixir modules under `workspace/tools/<name>/`.
    - Skills are Markdown directories under `workspace/skills/<name>/`.
    - Available skill cards are injected into the runtime prompt as `id` + `description`.
    - Use `skill_get` with the listed skill id to load the full `SKILL.md` body on demand.
    - Use `skill_capture` to save a reusable local Markdown skill.
    - Use tools for executable capabilities; use skills for reusable guidance.
    """
  end

  defp soul_template do
    """
    # Soul

    Persona, values, voice, and long-term operating principles. Durable self-definition belongs in IDENTITY.md.

    ## Personality

    - Helpful and friendly
    - Concise and direct
    - Honest — never claim to have done something without actually doing it

    ## Values

    - Accuracy over speed
    - Always verify actions with tools before reporting results
    - Transparency in actions
    - File edits do not activate CODE changes. Use `self_update deploy` when runtime activation is required.
    - Do not infer restarts or hot reload from file writes or process age. The current call may still run old code until deploy completes.

    ## Communication Style

    - Reply in the same language the user writes in
    - Be clear and direct
    - Ask clarifying questions when the request is ambiguous
    """
  end

  defp user_template do
    """
    # User Profile

    Information about the user to personalize interactions.

    ## Basic Information

    - **Name**: (user's name)
    - **Timezone**: (e.g., UTC+8)
    - **Language**: (preferred language)

    ## Preferences

    - Communication style: casual / professional / technical
    - Response length: brief / detailed / adaptive

    ## Work Context

    - **Primary Role**: (developer, researcher, etc.)
    - **Main Projects**: (what they're working on)

    ## Collaboration Preferences

    - Preferred workflow: (sync/async, detailed/terse)
    - Notification preferences: (when to notify, what channels)
    - Working hours: (if relevant for scheduling)

    ---

    *Edit this file to customize the assistant's knowledge about you.*
    """
  end

  defp memory_template do
    """
    # Long-term Memory

    This file stores important facts that persist across conversations.

    ## Environment Facts

    (Stable facts about runtime, infrastructure, and toolchain)

    ## Project Conventions

    (Important project-specific conventions and decisions)

    ## Project Context

    (Information about ongoing projects)

    ## Workflow Lessons

    (Reusable lessons learned from successful or failed execution paths)

    ---

    *This file is automatically updated when important information should be remembered.*
    """
  end

  defp history_template do
    """
    # History
    """
  end
end
