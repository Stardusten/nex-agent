defmodule Nex.Agent.RuntimeWatcherTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Runtime.Watcher

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-watcher-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    File.mkdir_p!(Path.join(workspace, "tools"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    config_path = Path.join(workspace, "config.json")
    File.write!(config_path, "{}\n")

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace, config_path: config_path}
  end

  test "watcher triggers runtime reload for prompt layer changes", %{
    workspace: workspace,
    config_path: config_path
  } do
    parent = self()
    name = :"runtime_watcher_prompt_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Watcher,
       name: name,
       workspace: workspace,
       config_path: config_path,
       poll_interval_ms: false,
       runtime_reload_fun: fn opts ->
         send(parent, {:reload, Keyword.fetch!(opts, :changed_paths)})
         {:ok, :snapshot}
       end,
       skills_reload_fun: fn ->
         send(parent, :skills_reload)
         :ok
       end,
       tools_reload_fun: fn ->
         send(parent, :tools_reload)
         :ok
       end}
    )

    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\nchanged\n")
    send(Process.whereis(name), :poll)

    assert_receive {:reload, changed_paths}
    assert Enum.any?(changed_paths, &String.ends_with?(&1, "SOUL.md"))
    refute_receive :skills_reload, 50
    refute_receive :tools_reload, 50
  end

  test "watcher reloads skills before runtime when skills path changes", %{
    workspace: workspace,
    config_path: config_path
  } do
    parent = self()
    name = :"runtime_watcher_skills_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Watcher,
       name: name,
       workspace: workspace,
       config_path: config_path,
       poll_interval_ms: false,
       runtime_reload_fun: fn opts ->
         send(parent, {:event, :runtime_reload, Keyword.fetch!(opts, :changed_paths)})
         {:ok, :snapshot}
       end,
       skills_reload_fun: fn ->
         send(parent, {:event, :skills_reload})
         :ok
       end,
       tools_reload_fun: fn ->
         send(parent, {:event, :tools_reload})
         :ok
       end}
    )

    File.mkdir_p!(Path.join(workspace, "skills/demo"))
    File.write!(Path.join(workspace, "skills/demo/SKILL.md"), "# Demo\n")
    send(Process.whereis(name), :poll)

    assert_receive {:event, :skills_reload}
    assert_receive {:event, :runtime_reload, changed_paths}
    assert Enum.any?(changed_paths, &String.contains?(&1, "/skills/"))
    refute_receive {:event, :tools_reload}, 50
  end

  test "watcher reloads tools before runtime when tools path changes", %{
    workspace: workspace,
    config_path: config_path
  } do
    parent = self()
    name = :"runtime_watcher_tools_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Watcher,
       name: name,
       workspace: workspace,
       config_path: config_path,
       poll_interval_ms: false,
       runtime_reload_fun: fn opts ->
         send(parent, {:event, :runtime_reload, Keyword.fetch!(opts, :changed_paths)})
         {:ok, :snapshot}
       end,
       skills_reload_fun: fn ->
         send(parent, {:event, :skills_reload})
         :ok
       end,
       tools_reload_fun: fn ->
         send(parent, {:event, :tools_reload})
         :ok
       end}
    )

    File.write!(Path.join(workspace, "tools/demo.exs"), "# tool\n")
    send(Process.whereis(name), :poll)

    assert_receive {:event, :tools_reload}
    assert_receive {:event, :runtime_reload, changed_paths}
    assert Enum.any?(changed_paths, &String.contains?(&1, "/tools/"))
    refute_receive {:event, :skills_reload}, 50
  end
end
