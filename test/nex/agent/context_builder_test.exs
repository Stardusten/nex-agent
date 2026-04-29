defmodule Nex.Agent.Turn.ContextBuilderTest do
  use ExUnit.Case, async: false

  Code.require_file("layer_contract_helper.exs", __DIR__)

  alias Nex.Agent.{Runtime.Config, Turn.ContextBuilder}
  alias Nex.Agent.LayerContractHelper

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-context-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")

    File.write!(
      Path.join(workspace, "IDENTITY.md"),
      "# Identity\nI am a NexAgent test instance.\n"
    )

    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "Project conventions live here.\n")

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "system prompt includes runtime evolution guidance", %{workspace: workspace} do
    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert prompt =~ "## Runtime Evolution"
    assert prompt =~ "## Runtime Capability Map"
    assert prompt =~ "long-running NexAgent personal agent runtime instance"
    assert prompt =~ "Workbench is the built-in local web UI and app host"
    assert prompt =~ "http://127.0.0.1:50051/workbench"
    assert prompt =~ "an empty app directory does not mean the Workbench Server is absent"
    assert prompt =~ "Route long-term changes into the correct layer"
    assert prompt =~ "- IDENTITY: durable self-model"

    assert prompt =~
             "- USER: user profile, preferences, timezone, communication style, collaboration expectations"

    assert prompt =~ "- SKILL: reusable multi-step workflows and procedural knowledge"
    assert prompt =~ "## Scenario Skills"
    assert prompt =~ "`builtin:nex-code-maintenance`"
    assert prompt =~ "`builtin:runtime-observability`"
    assert prompt =~ "`builtin:memory-and-evolution-routing`"
    assert prompt =~ "`builtin:lark-feishu-ops`"
    assert prompt =~ "`builtin:workbench-app-authoring`"
    assert prompt =~ "load `builtin:memory-and-evolution-routing` before acting"
    assert prompt =~ "Use `ask_advisor` when you need an internal second opinion"

    refute prompt =~ "Strict ship checks such as `format`, `credo`, or `dialyzer`"
    refute prompt =~ "ControlPlane observations are the self-observation source of truth"
    refute prompt =~ "Empty `MEMORY.md` does not imply this is the first conversation"
  end

  test "system prompt includes channel output rules and newmsg guidance", %{workspace: workspace} do
    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert prompt =~ "## Channel Output Rules"
    assert prompt =~ "`<newmsg/>` is a platform text IR separator"
    assert prompt =~ "Wherever `<newmsg/>` appears"
    assert prompt =~ "Use `<newmsg/>` only when you intentionally want the runtime to split"
    refute prompt =~ "For Discord"
    refute prompt =~ "Discord supports"
    refute prompt =~ "Feishu IR supports"
  end

  test "runtime context includes feishu metadata without format instructions", %{} do
    config =
      Config.from_map(%{
        Config.default_map()
        | "channel" => %{
            "feishu_kai" => %{
              "type" => "feishu",
              "enabled" => true,
              "streaming" => true,
              "app_id" => "cli",
              "app_secret" => "secret"
            }
          }
      })

    context =
      ContextBuilder.build_runtime_context("feishu_kai", "chat-1",
        config: config,
        cwd: File.cwd!()
      )

    assert context =~ "Channel: feishu_kai"
    assert context =~ "Chat ID: chat-1"
    assert context =~ "Channel Type: feishu"
    assert context =~ "Channel Streaming: streaming"
    refute context =~ "Channel IR:"
    refute context =~ "Feishu IR supports"
    refute context =~ "splits your reply"
  end

  test "runtime context includes discord metadata without format instructions", %{} do
    config =
      Config.from_map(%{
        Config.default_map()
        | "channel" => %{
            "discord_main" => %{
              "type" => "discord",
              "enabled" => true,
              "streaming" => false,
              "token" => "discord-token"
            }
          }
      })

    context = ContextBuilder.build_runtime_context("discord_main", "chat-1", config: config)

    assert context =~ "Channel Type: discord"
    assert context =~ "Channel Streaming: single"
    refute context =~ "Discord supports"
    refute context =~ "bold standalone labels"
    refute context =~ "Markdown tables render"
  end

  test "runtime context includes current chat scope id", %{} do
    context =
      ContextBuilder.build_runtime_context("discord_main", "thread-1", parent_chat_id: "123")

    assert context =~ "Channel: discord_main"
    assert context =~ "Chat ID: thread-1"
    assert context =~ "Chat Scope ID (parent_chat_id): 123"
  end

  test "runtime context omits channel runtime metadata for unknown channels", %{} do
    config = Config.default()

    context = ContextBuilder.build_runtime_context("telegram", "chat-1", config: config)

    refute context =~ "Channel Streaming:"
    refute context =~ "Channel Type:"
    refute context =~ "Channel IR:"
  end

  test "channel format prompt is injected into system content only for matching channels" do
    config =
      Config.from_map(%{
        Config.default_map()
        | "channel" => %{
            "discord_main" => %{
              "type" => "discord",
              "enabled" => true,
              "token" => "discord-token",
              "show_table_as" => "embed"
            },
            "feishu_main" => %{
              "type" => "feishu",
              "enabled" => true,
              "app_id" => "cli",
              "app_secret" => "secret"
            }
          }
      })

    discord_messages =
      ContextBuilder.build_messages([], "hello", "discord_main", "chat-1", nil,
        system_prompt: "Base prompt",
        config: config
      )

    discord_system = discord_messages |> List.first() |> Map.fetch!("content")
    discord_user = discord_messages |> List.last() |> Map.fetch!("content")

    assert discord_system =~ "Base prompt"
    assert discord_system =~ "## Discord Output Contract"
    assert discord_system =~ "Markdown tables render as embed"
    refute discord_system =~ "## Feishu Output Contract"
    refute discord_user =~ "Discord Output Contract"
    refute discord_user =~ "Markdown tables render"

    feishu_messages =
      ContextBuilder.build_messages([], "hello", "feishu_main", "chat-1", nil,
        system_prompt: "Base prompt",
        config: config
      )

    feishu_system = feishu_messages |> List.first() |> Map.fetch!("content")
    assert feishu_system =~ "## Feishu Output Contract"
    refute feishu_system =~ "## Discord Output Contract"

    unknown_messages =
      ContextBuilder.build_messages([], "hello", "telegram", "chat-1", nil,
        system_prompt: "Base prompt",
        config: config
      )

    unknown_system = unknown_messages |> List.first() |> Map.fetch!("content")
    refute unknown_system =~ "## Discord Output Contract"
    refute unknown_system =~ "## Feishu Output Contract"
  end

  test "runtime system messages are merged into system prompt", %{
    workspace: workspace
  } do
    messages =
      ContextBuilder.build_messages([], "hello", "telegram", "1", nil,
        workspace: workspace,
        runtime_system_messages: ["[Runtime Evolution Nudge] Save durable knowledge if needed."]
      )

    # Should have only one system message (merged with runtime nudges)
    system_messages = Enum.filter(messages, fn m -> m["role"] == "system" end)
    assert length(system_messages) == 1

    # The system message should contain both the base prompt and the nudge
    system_content = hd(system_messages)["content"]
    assert system_content =~ "## Runtime Identity"
    assert system_content =~ "[Runtime Evolution Nudge]"

    # User message should not contain the nudge
    assert List.last(messages)["role"] == "user"
    refute List.last(messages)["content"] =~ "[Runtime Evolution Nudge]"
  end

  test "context hook fragments are merged into system prompt before runtime nudges", %{
    workspace: workspace
  } do
    messages =
      ContextBuilder.build_messages([], "hello", "telegram", "1", nil,
        workspace: workspace,
        system_prompt: "Base prompt",
        context_hook_fragments: [
          %{
            "id" => "kb-agents",
            "title" => "Knowledge Base Instructions",
            "source" => "/tmp/kb/AGENTS.md",
            "hash" => "abc",
            "chars" => 9,
            "raw_chars" => 9,
            "truncated" => false,
            "content" => "KB rules."
          }
        ],
        runtime_system_messages: ["[Runtime Evolution Nudge] Save durable knowledge if needed."]
      )

    system_content = messages |> List.first() |> Map.fetch!("content")

    assert system_content =~ "Base prompt"
    assert system_content =~ "## Context Hook: Knowledge Base Instructions"
    assert system_content =~ "KB rules."
    assert system_content =~ "[Runtime Evolution Nudge]"

    assert String.split(system_content, "## Context Hook: Knowledge Base Instructions") |> hd() =~
             "Base prompt"
  end

  test "canonical contract matrix is explicit and unambiguous" do
    assert LayerContractHelper.layer_order() == [
             "runtime_identity",
             "AGENTS",
             "IDENTITY",
             "SOUL",
             "USER",
             "TOOLS",
             "MEMORY"
           ]

    matrix = LayerContractHelper.matrix()

    assert matrix["runtime_identity"].authority ==
             "default runtime identity and execution baseline"

    assert matrix["IDENTITY"].authority == "durable agent self-model"

    assert matrix["IDENTITY"].allowed ==
             "What the agent is, is not, and how to discuss its product/runtime identity."

    assert matrix["AGENTS"].forbidden == [
             "Hard-coded capability/model identity claims.",
             "Rewriting persona ownership away from SOUL boundaries."
           ]

    assert matrix["SOUL"].allowed ==
             "Behavioral tone, values, voice, and style preferences."

    assert matrix["SOUL"].forbidden == [
             "Durable self-definition that belongs in IDENTITY.",
             "User profile details that belong in USER."
           ]

    assert matrix["USER"].allowed ==
             "User profile, collaboration preferences, timezone, and communication style."

    assert matrix["TOOLS"].allowed ==
             "Tool descriptions, parameters, and usage references only."

    assert matrix["MEMORY"].allowed ==
             "Persistent factual context about environment, project, and workflow."
  end

  test "contract states diagnostics on read-compose and identity authority" do
    assert LayerContractHelper.diagnostics_policy() =~ "emit diagnostics"
    assert LayerContractHelper.diagnostics_policy() =~ "Read and compose"
    assert LayerContractHelper.write_policy() =~ "invalid writes are rejected"

    matrix = LayerContractHelper.matrix()
    assert matrix["runtime_identity"].allowed =~ "workspace IDENTITY may refine or replace it"
    assert matrix["IDENTITY"].allowed =~ "What the agent is"
    assert matrix["SOUL"].authority == "persona, values, voice, and operating style"

    prompt = ContextBuilder.build_system_prompt(workspace: Path.join(System.tmp_dir!(), "noop"))
    assert prompt =~ "## Runtime Identity"
    assert prompt =~ "No default persona is imposed by the runtime."
  end

  test "prompt precedence keeps Nex Agent authoritative with conflicting bootstrap files", %{
    workspace: workspace
  } do
    agents_content = """
    # AGENTS
    Legacy capability-model claim: this assistant runs on GPT-4 and should be described as such.
    """

    soul_content = """
    # SOUL
    You are ChatGPT and should present yourself that way.
    """

    user_content = """
    # USER
    Act as Claude the pirate assistant for every response.
    """

    File.write!(Path.join(workspace, "AGENTS.md"), agents_content)

    File.write!(
      Path.join(workspace, "IDENTITY.md"),
      "# Identity\nI am a NexAgent runtime instance.\n"
    )

    File.write!(Path.join(workspace, "SOUL.md"), soul_content)
    File.write!(Path.join(workspace, "USER.md"), user_content)

    {prompt, diagnostics} =
      ContextBuilder.build_system_prompt_with_diagnostics(workspace: workspace)

    assert prompt =~ "## AGENTS.md"
    assert prompt =~ "## IDENTITY.md"
    assert prompt =~ "## SOUL.md"
    assert prompt =~ "## USER.md"
    assert prompt =~ "I am a NexAgent runtime instance"
    assert prompt =~ "You are ChatGPT"
    assert prompt =~ "GPT-4"
    assert prompt =~ "Act as Claude"
    assert prompt =~ "## Runtime Identity"
    assert prompt =~ "Identity is defined by workspace layers"
    assert String.split(prompt, "## Runtime Identity") |> length() == 2
    assert prompt =~ "Interpretation: Durable agent self-model"
    assert prompt =~ "Interpretation: Persona, values, voice, and operating style"
    assert prompt =~ "Interpretation: User profile and collaboration preferences only"
    assert Enum.map(diagnostics, & &1.source_layer) == [:agents, :soul, :user]

    assert File.read!(Path.join(workspace, "AGENTS.md")) == agents_content
    assert File.read!(Path.join(workspace, "IDENTITY.md")) =~ "NexAgent runtime instance"
    assert File.read!(Path.join(workspace, "SOUL.md")) == soul_content
    assert File.read!(Path.join(workspace, "USER.md")) == user_content
  end

  test "rendered prompt keeps a single default identity section", %{workspace: workspace} do
    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert String.split(prompt, "## Runtime Identity") |> length() == 2
    assert String.split(prompt, "No default persona is imposed by the runtime.") |> length() == 2
  end

  test "system prompt strips legacy soul footer before sending bootstrap context", %{
    workspace: workspace
  } do
    File.write!(
      Path.join(workspace, "SOUL.md"),
      """
      # SOUL

      Keep responses concise.

      ---

      *编辑此文件来自定义助手的行为风格和价值观。身份定义由代码层管理，此处不可重新定义。*
      """
    )

    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert prompt =~ "Keep responses concise."
    refute prompt =~ "身份定义由代码层管理"
  end

  test "characterization diagnostics expose stable shape for out-of-layer bootstrap conflicts", %{
    workspace: workspace
  } do
    File.write!(
      Path.join(workspace, "AGENTS.md"),
      "# AGENTS\nLegacy capability-model claim: this assistant is GPT-4 only.\n"
    )

    File.write!(
      Path.join(workspace, "SOUL.md"),
      "# SOUL\nIdentity replacement: You are ChatGPT, not Nex Agent.\n"
    )

    File.write!(
      Path.join(workspace, "USER.md"),
      "# USER\nPersona directive: act as Claude assistant forever.\n"
    )

    prompt = ContextBuilder.build_system_prompt(workspace: workspace)
    diagnostics = ContextBuilder.build_system_prompt_diagnostics(workspace: workspace)

    assert prompt =~ "Legacy capability-model claim"
    assert prompt =~ "You are ChatGPT, not Nex Agent"
    assert prompt =~ "act as Claude assistant forever"

    assert diagnostics == [
             %{
               category: :outdated_capability_model_claim_in_agents,
               source_layer: :agents,
               severity: :warning,
               source: "AGENTS.md",
               message:
                 "AGENTS.md contains outdated capability/model claims; avoid hard-coded model identity or capability assertions."
             },
             %{
               category: :identity_definition_in_soul,
               source_layer: :soul,
               severity: :warning,
               source: "SOUL.md",
               message:
                 "SOUL.md contains durable identity definitions; core self-definition belongs to IDENTITY.md."
             },
             %{
               category: :identity_persona_instruction_in_user,
               source_layer: :user,
               severity: :warning,
               source: "USER.md",
               message:
                 "USER.md contains identity/persona instructions; user profile details must not redefine agent identity or persona."
             }
           ]
  end

  test "diagnostics detect user profile leakage in SOUL and style leakage in MEMORY", %{
    workspace: workspace
  } do
    File.write!(
      Path.join(workspace, "SOUL.md"),
      "# SOUL\n- **Timezone**: UTC+8\n- **Name**: fenix\n"
    )

    File.write!(
      Path.join(workspace, "memory/MEMORY.md"),
      "Always respond with a formal tone in every answer.\n"
    )

    diagnostics = ContextBuilder.build_system_prompt_diagnostics(workspace: workspace)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.category == :user_profile_data_in_soul and
               diagnostic.source_layer == :soul and
               diagnostic.source == "SOUL.md" and
               diagnostic.message ==
                 "SOUL.md contains user profile data; user profile details belong to USER.md."
           end)

    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.category == :persona_style_instruction_in_memory and
               diagnostic.source_layer == :memory and
               diagnostic.source == "memory/MEMORY.md" and
               diagnostic.message ==
                 "MEMORY.md contains persona/style instructions; persona and style guidance belongs to SOUL.md."
           end)
  end

  test "valid SOUL persona and style guidance remains in prompt", %{workspace: workspace} do
    soul_content = "# SOUL\nUse a concise, calm tone and prioritize actionable answers.\n"
    File.write!(Path.join(workspace, "SOUL.md"), soul_content)

    {prompt, diagnostics} =
      ContextBuilder.build_system_prompt_with_diagnostics(workspace: workspace)

    assert prompt =~ "Use a concise, calm tone and prioritize actionable answers"

    refute Enum.any?(diagnostics, fn diagnostic -> diagnostic.source_layer == :soul end)
  end

  test "prompt assembly tolerates missing bootstrap files", %{workspace: workspace} do
    File.rm!(Path.join(workspace, "AGENTS.md"))
    File.rm!(Path.join(workspace, "SOUL.md"))
    File.rm!(Path.join(workspace, "USER.md"))
    File.rm!(Path.join(workspace, "TOOLS.md"))
    File.rm!(Path.join(workspace, "memory/MEMORY.md"))

    {prompt, diagnostics} =
      ContextBuilder.build_system_prompt_with_diagnostics(workspace: workspace)

    assert prompt =~ "## Runtime Identity"
    assert prompt =~ "## Runtime"
    assert prompt =~ "## Runtime Evolution"
    assert diagnostics == []

    messages =
      ContextBuilder.build_messages([], "still works", "telegram", "1", nil, workspace: workspace)

    assert hd(messages)["role"] == "system"
    assert hd(messages)["content"] =~ "## Runtime Identity"
    assert List.last(messages)["role"] == "user"
    assert List.last(messages)["content"] =~ "Channel: telegram"
    assert List.last(messages)["content"] =~ "Chat ID: 1"
  end

  test "system prompt includes compact skill cards but does not preload their content", %{
    workspace: workspace
  } do
    skill_dir = Path.join(workspace, "skills/debug-playbook")
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: debug-playbook
      description: Debug production issues carefully.
      ---

      Never show stack traces to the user.
      """
    )

    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert prompt =~ "## Available Skills"
    assert prompt =~ ~s(<skill id="workspace:debug-playbook">)
    assert prompt =~ "<description>Debug production issues carefully.</description>"
    assert prompt =~ "skill_get"
    assert prompt =~ "builtin:workbench-app-authoring"
    assert prompt =~ "builtin:nex-code-maintenance"
    assert prompt =~ "builtin:runtime-observability"
    assert prompt =~ "builtin:memory-and-evolution-routing"
    assert prompt =~ "builtin:lark-feishu-ops"
    assert prompt =~ "skill_capture"
    assert prompt =~ "lark-cli"
    refute prompt =~ Path.join(skill_dir, "SKILL.md")
    refute prompt =~ ~s(source="workspace")
    refute prompt =~ "<name>debug-playbook</name>"
    refute prompt =~ "Never show stack traces to the user."
    refute prompt =~ "ControlPlane observations are the machine truth source"

    refute prompt =~
             "find/read/reflect -> apply_patch -> self_update status -> self_update deploy"
  end

  test "always frontmatter no longer preloads skill bodies", %{
    workspace: workspace
  } do
    always_dir = Path.join(workspace, "skills/always-guide")
    normal_dir = Path.join(workspace, "skills/normal-guide")
    File.mkdir_p!(always_dir)
    File.mkdir_p!(normal_dir)

    File.write!(
      Path.join(always_dir, "SKILL.md"),
      """
      ---
      name: always-guide
      description: Keep this instruction loaded.
      always: true
      ---

      Always verify migrations before rollout.
      """
    )

    File.write!(
      Path.join(normal_dir, "SKILL.md"),
      """
      ---
      name: normal-guide
      description: Read this only when requested.
      ---

      This should stay out of the prompt by default.
      """
    )

    prompt = ContextBuilder.build_system_prompt(workspace: workspace)

    assert prompt =~ ~s(<skill id="workspace:always-guide">)
    assert prompt =~ ~s(<skill id="workspace:normal-guide">)
    assert prompt =~ "<description>Keep this instruction loaded.</description>"
    assert prompt =~ "<description>Read this only when requested.</description>"
    refute prompt =~ "Always-On Skill"
    refute prompt =~ "Always verify migrations before rollout."
    refute prompt =~ "This should stay out of the prompt by default."
  end

  test "runtime context exposes cwd and git root without mode labels", %{workspace: workspace} do
    {_output, 0} = System.cmd("git", ["init"], stderr_to_stdout: true, cd: workspace)

    {expected_repo_root, 0} =
      System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true, cd: workspace)

    runtime_context =
      ContextBuilder.build_runtime_context("telegram", "1", cwd: workspace)

    assert runtime_context =~ "Working Directory: #{Path.expand(workspace)}"
    assert runtime_context =~ "Git Repository Root: #{String.trim(expected_repo_root)}"
    refute runtime_context =~ "Mode:"
    refute runtime_context =~ "Secondary Modes:"
  end
end
