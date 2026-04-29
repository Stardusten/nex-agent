defmodule Nex.Agent.Capability.SkillsTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Runtime.Config, Capability.Skills}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-skills-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "skills"))

    if Process.whereis(Skills) == nil do
      start_supervised!({Skills, []})
    end

    on_exit(fn ->
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "draft skills stay out of llm discovery and execution until published", %{
    workspace: workspace
  } do
    assert {:ok, draft} =
             Skills.create(
               %{
                 name: "draft_memory_probe",
                 description: "[Draft] Check stuck memory state",
                 content: "<!-- status: draft, source: evolution -->\n\nUse this draft.",
                 user_invocable: false
               },
               workspace: workspace
             )

    assert draft.draft

    refute Enum.any?(
             Skills.for_llm(workspace: workspace),
             &(&1["id"] == "workspace:draft_memory_probe")
           )

    assert {:error, reason} =
             Skills.execute("draft_memory_probe", %{"probe" => "now"}, workspace: workspace)

    assert reason =~ "still draft-only"

    assert {:ok, published} = Skills.publish_draft("draft_memory_probe", workspace: workspace)
    refute published.draft

    assert Enum.any?(
             Skills.for_llm(workspace: workspace),
             &(&1["id"] == "workspace:draft_memory_probe")
           )

    assert {:ok, %{result: "Use this draft."}} =
             Skills.execute("draft_memory_probe", %{}, workspace: workspace)
  end

  test "catalog exposes model-invocable cards without loading bodies", %{workspace: workspace} do
    File.mkdir_p!(Path.join(workspace, "skills/user-hidden"))
    File.mkdir_p!(Path.join(workspace, "skills/model-hidden"))
    File.mkdir_p!(Path.join(workspace, "skills/normal-guide"))

    File.write!(
      Path.join(workspace, "skills/user-hidden/SKILL.md"),
      """
      ---
      name: user-hidden
      description: Use when model should see a non-menu workflow.
      user-invocable: false
      ---

      Hidden from user menu but model-visible.
      """
    )

    File.write!(
      Path.join(workspace, "skills/model-hidden/SKILL.md"),
      """
      ---
      name: model-hidden
      description: This must not be model visible.
      disable-model-invocation: true
      ---

      Model must not read this by default.
      """
    )

    File.write!(
      Path.join(workspace, "skills/normal-guide/SKILL.md"),
      """
      ---
      name: normal-guide
      description: Use for ordinary skill catalog tests.
      ---

      Body should load only after skill_get.
      """
    )

    cards = Skills.catalog(workspace: workspace)

    assert Enum.any?(cards, &(&1["id"] == "builtin:workbench-app-authoring"))
    assert Enum.any?(cards, &(&1["id"] == "builtin:nex-code-maintenance"))
    assert Enum.any?(cards, &(&1["id"] == "builtin:runtime-observability"))
    assert Enum.any?(cards, &(&1["id"] == "builtin:memory-and-evolution-routing"))
    assert Enum.any?(cards, &(&1["id"] == "builtin:lark-feishu-ops"))
    assert Enum.any?(cards, &(&1["id"] == "workspace:user-hidden"))
    assert Enum.any?(cards, &(&1["id"] == "workspace:normal-guide"))
    refute Enum.any?(cards, &(&1["id"] == "workspace:model-hidden"))

    prompt = Skills.catalog_prompt(workspace: workspace)

    assert prompt =~ ~s(<skill id="builtin:nex-code-maintenance">)
    assert prompt =~ ~s(<skill id="builtin:runtime-observability">)
    assert prompt =~ ~s(<skill id="builtin:memory-and-evolution-routing">)
    assert prompt =~ ~s(<skill id="builtin:lark-feishu-ops">)
    assert prompt =~ ~s(<skill id="workspace:normal-guide">)
    assert prompt =~ "<description>Use for ordinary skill catalog tests.</description>"
    refute prompt =~ "Body should load only after skill_get."
    refute prompt =~ "path="
    refute prompt =~ ~s(source="workspace")
    refute prompt =~ "<name>normal-guide</name>"
  end

  test "builtin workbench authoring skill is loadable by id", %{
    workspace: workspace
  } do
    assert {:ok, card} =
             Skills.resolve_catalog_skill("builtin:workbench-app-authoring", workspace: workspace)

    assert card["path"] =~
             "priv/plugins/builtin/skill.workbench-app-authoring/skills/workbench-app-authoring/SKILL.md"

    assert {:ok, loaded} = Skills.read_catalog_skill(card)

    assert loaded["content"] =~ "workspace/workbench/apps/<id>/"
    assert loaded["content"] =~ "Workbench Server"
    assert loaded["content"] =~ "http://127.0.0.1:<port>/workbench"
    assert loaded["content"] =~ "empty `workspace/workbench/apps/` directory"
    assert loaded["content"] =~ "`find`"
    assert loaded["content"] =~ "`read`"
    assert loaded["content"] =~ "`apply_patch`"
    refute loaded["content"] =~ "workbench_app"
    refute loaded["content"] =~ "write_file"
    refute loaded["content"] =~ "save_manifest"
    refute loaded["content"] =~ "stock schema"
    refute loaded["content"] =~ "notes schema"
  end

  test "disabled builtin skill plugin removes skill card and skill_get target", %{
    workspace: workspace
  } do
    config =
      Config.from_map(%{
        "plugins" => %{"disabled" => ["builtin:skill.lark-feishu-ops"]}
      })

    cards = Skills.catalog(workspace: workspace, config: config)

    refute Enum.any?(cards, &(&1["id"] == "builtin:lark-feishu-ops"))

    assert {:error, reason} =
             Skills.resolve_catalog_skill("builtin:lark-feishu-ops",
               workspace: workspace,
               config: config
             )

    assert reason == "Skill not found: builtin:lark-feishu-ops"
  end

  test "prompt extraction builtin skills are loadable by id", %{
    workspace: workspace
  } do
    assert {:ok, code_card} =
             Skills.resolve_catalog_skill("builtin:nex-code-maintenance", workspace: workspace)

    assert {:ok, code_skill} = Skills.read_catalog_skill(code_card)
    assert code_skill["content"] =~ "self_update deploy"
    assert code_skill["content"] =~ "ReqLLM"
    assert code_skill["content"] =~ ~s(%{type: "tool", name: "tool_name"})

    assert {:ok, observe_card} =
             Skills.resolve_catalog_skill("builtin:runtime-observability", workspace: workspace)

    assert {:ok, observe_skill} = Skills.read_catalog_skill(observe_card)
    assert observe_skill["content"] =~ "ControlPlane observations"
    assert observe_skill["content"] =~ "observe summary"

    assert {:ok, memory_card} =
             Skills.resolve_catalog_skill(
               "builtin:memory-and-evolution-routing",
               workspace: workspace
             )

    assert {:ok, memory_skill} = Skills.read_catalog_skill(memory_card)
    assert memory_skill["content"] =~ "memory_consolidate"
    assert memory_skill["content"] =~ "evolution_candidate"

    assert {:ok, feishu_card} =
             Skills.resolve_catalog_skill("builtin:lark-feishu-ops", workspace: workspace)

    assert {:ok, feishu_skill} = Skills.read_catalog_skill(feishu_card)
    assert feishu_skill["content"] =~ "lark-cli"
    assert feishu_skill["content"] =~ "local_image_path"
  end
end
