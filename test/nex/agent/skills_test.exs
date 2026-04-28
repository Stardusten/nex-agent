defmodule Nex.Agent.SkillsTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Skills

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
    assert Enum.any?(cards, &(&1["id"] == "workspace:user-hidden"))
    assert Enum.any?(cards, &(&1["id"] == "workspace:normal-guide"))
    refute Enum.any?(cards, &(&1["id"] == "workspace:model-hidden"))

    prompt = Skills.catalog_prompt(workspace: workspace)

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

    assert {:ok, loaded} = Skills.read_catalog_skill(card)

    assert loaded["content"] =~ "workspace/workbench/apps/<id>/"
    assert loaded["content"] =~ "`find`"
    assert loaded["content"] =~ "`read`"
    assert loaded["content"] =~ "`apply_patch`"
    refute loaded["content"] =~ "workbench_app"
    refute loaded["content"] =~ "write_file"
    refute loaded["content"] =~ "save_manifest"
    refute loaded["content"] =~ "stock schema"
    refute loaded["content"] =~ "notes schema"
  end
end
