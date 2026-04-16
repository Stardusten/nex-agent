defmodule Nex.Agent.RuntimeTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Config, Runtime, Skills}
  alias Nex.Agent.Runtime.Snapshot

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-runtime-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills/always-guide"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\nRuntime AGENTS layer.\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\nRuntime SOUL layer.\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\nRuntime USER layer.\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\nRuntime TOOLS layer.\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\nRuntime memory.\n")

    File.write!(
      Path.join(workspace, "skills/always-guide/SKILL.md"),
      """
      ---
      name: always-guide
      description: Always loaded test guide.
      always: true
      ---

      Runtime always skill instruction.
      """
    )

    previous_workspace = Application.get_env(:nex_agent, :workspace_path)
    Application.put_env(:nex_agent, :workspace_path, workspace)
    Skills.load()

    Runtime.reload(workspace: workspace, changed_paths: [])

    on_exit(fn ->
      restore_env(:workspace_path, previous_workspace)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "initial snapshot is readable and includes prompt tools and skills", %{
    workspace: workspace
  } do
    assert {:ok, %Snapshot{} = snapshot} = Runtime.current()

    assert snapshot.version >= 1
    assert snapshot.workspace == workspace
    assert %Config{} = snapshot.config
    assert snapshot.prompt.system_prompt =~ "Runtime AGENTS layer."
    assert is_list(snapshot.prompt.diagnostics)
    assert is_binary(snapshot.prompt.hash)
    assert snapshot.tools.definitions_all != []
    assert snapshot.tools.definitions_subagent != []
    assert snapshot.tools.definitions_cron != []
    assert is_binary(snapshot.tools.hash)
    assert snapshot.skills.always_instructions =~ "Runtime always skill instruction."
    assert is_binary(snapshot.skills.hash)
  end

  test "reload succeeds, increments version, broadcasts event, and records changed paths", %{
    workspace: workspace
  } do
    assert {:ok, before_snapshot} = Runtime.current()
    assert :ok = Runtime.subscribe()

    assert {:ok, %Snapshot{} = after_snapshot} =
             Runtime.reload(workspace: workspace, changed_paths: ["SOUL.md"])

    assert after_snapshot.version == before_snapshot.version + 1
    assert after_snapshot.changed_paths == ["SOUL.md"]

    assert_receive {:runtime_updated,
                    %{
                      old_version: old_version,
                      new_version: new_version,
                      changed_paths: ["SOUL.md"]
                    }}

    assert old_version == before_snapshot.version
    assert new_version == after_snapshot.version
    assert Runtime.current_version() == after_snapshot.version
  end

  test "reload failure does not replace last valid snapshot", %{workspace: workspace} do
    assert {:ok, before_snapshot} = Runtime.current()

    assert {:error, :prompt_failed} =
             Runtime.reload(
               workspace: workspace,
               prompt_builder: fn _opts -> {:error, :prompt_failed} end
             )

    assert {:ok, after_snapshot} = Runtime.current()
    assert after_snapshot.version == before_snapshot.version
    assert after_snapshot.prompt.hash == before_snapshot.prompt.hash
  end

  test "workspace resolver prefers explicit option over application workspace", %{
    workspace: app_workspace
  } do
    explicit_workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-runtime-explicit-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(explicit_workspace, "memory"))
    File.write!(Path.join(explicit_workspace, "AGENTS.md"), "# AGENTS\nExplicit workspace.\n")
    File.write!(Path.join(explicit_workspace, "memory/MEMORY.md"), "# Memory\n")

    on_exit(fn -> File.rm_rf!(explicit_workspace) end)

    assert {:ok, snapshot} = Runtime.reload(workspace: explicit_workspace)

    assert snapshot.workspace == explicit_workspace
    assert snapshot.workspace != app_workspace
    assert snapshot.prompt.system_prompt =~ "Explicit workspace."
  end

  test "runtime initial snapshot can read already-started skills and tool registry", %{
    workspace: workspace
  } do
    name = :"runtime_dependency_test_#{System.unique_integer([:positive])}"

    assert {:ok, pid} = Runtime.start_link(name: name, workspace: workspace)

    snapshot = :sys.get_state(pid).snapshot
    assert snapshot.skills.always_instructions =~ "Runtime always skill instruction."
    assert Enum.any?(snapshot.tools.definitions_all, &(&1["name"] == "read"))

    GenServer.stop(pid)
  end

  test "version 1 snapshot build failure fails fast" do
    name = :"runtime_fail_fast_test_#{System.unique_integer([:positive])}"
    previous_flag = Process.flag(:trap_exit, true)

    assert {:error, {:snapshot_build_failed, :boom}} =
             Runtime.start_link(name: name, prompt_builder: fn _opts -> {:error, :boom} end)

    Process.flag(:trap_exit, previous_flag)
  end

  defp restore_env(key, nil), do: Application.delete_env(:nex_agent, key)
  defp restore_env(key, value), do: Application.put_env(:nex_agent, key, value)
end
