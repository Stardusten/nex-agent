defmodule Nex.Agent.ContextBuilderTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.ContextBuilder

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-context-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
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
    assert prompt =~ "Route long-term changes into the correct layer"

    assert prompt =~
             "- USER: user profile, preferences, timezone, communication style, collaboration expectations"

    assert prompt =~ "- SKILL: reusable multi-step workflows and procedural knowledge"
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
    assert system_content =~ "Nex Agent"
    assert system_content =~ "[Runtime Evolution Nudge]"

    # User message should not contain the nudge
    assert List.last(messages)["role"] == "user"
    refute List.last(messages)["content"] =~ "[Runtime Evolution Nudge]"
  end
end
