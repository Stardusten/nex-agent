defmodule Nex.Agent.SelfModifyPipelineTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{CodeUpgrade, HotReload}
  alias Nex.Agent.SelfUpdate.{Deployer, ReleaseStore}
  alias Nex.Agent.SelfHealing.EventStore
  alias Nex.Agent.Tool.Registry

  @tmp_prefix "nex-selfmod-test"
  @repo_root File.cwd!()

  setup do
    tmp = Path.join(System.tmp_dir!(), "#{@tmp_prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    previous_repo_root = Application.get_env(:nex_agent, :repo_root)
    previous_workspace = Application.get_env(:nex_agent, :workspace_path)
    existing_artifacts = self_update_artifacts()

    targets = %{
      upgrade: tracked_target_spec("UpgradeTarget"),
      rollback: tracked_target_spec("RollbackTarget")
    }

    Application.put_env(:nex_agent, :repo_root, @repo_root)
    Application.put_env(:nex_agent, :workspace_path, tmp)

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    on_exit(fn ->
      if previous_repo_root do
        Application.put_env(:nex_agent, :repo_root, previous_repo_root)
      else
        Application.delete_env(:nex_agent, :repo_root)
      end

      if previous_workspace do
        Application.put_env(:nex_agent, :workspace_path, previous_workspace)
      else
        Application.delete_env(:nex_agent, :workspace_path)
      end

      unregister_test_tools()
      purge_test_modules(targets)
      restore_tracked_sources(targets)
      remove_new_artifacts(existing_artifacts)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, targets: targets}
  end

  test "hot_reload compiles and loads a new module from source", %{tmp: tmp} do
    source_path = Path.join(tmp, "hot_reload_test_tool.ex")
    code = fresh_tool_code("HotReloadTestTool", "hot_reload_test", "hello from hot reload")
    File.write!(source_path, code)

    result = HotReload.reload(source_path, code)

    assert result.reload_succeeded == true
    assert result.restart_required == false
    assert result.module == "Nex.Agent.Tool.HotReloadTestTool"
    assert CodeUpgrade.source_path(Nex.Agent.Tool.HotReloadTestTool) == source_path

    module = Nex.Agent.Tool.HotReloadTestTool
    assert {:ok, "hello from hot reload"} = module.execute(%{}, %{})
  end

  test "hot_reload swaps a registered tool in the registry", %{tmp: tmp} do
    ensure_registry!()

    v1_code = fresh_tool_code("SwapTestTool", "swap_test", "v1")
    v1_path = Path.join(tmp, "swap_test_tool.ex")
    File.write!(v1_path, v1_code)

    r1 = HotReload.reload(v1_path, v1_code)
    assert r1.reload_succeeded
    wait_for_registry("swap_test")
    assert {:ok, "v1"} = Registry.execute("swap_test", %{}, %{})

    v2_code = fresh_tool_code("SwapTestTool", "swap_test", "v2")
    File.write!(v1_path, v2_code)

    r2 = HotReload.reload_expected(v1_path, v2_code, Nex.Agent.Tool.SwapTestTool)
    assert r2.reload_succeeded
    wait_for_registry("swap_test")
    assert {:ok, "v2"} = Registry.execute("swap_test", %{}, %{})
  end

  test "self_update deploy writes a release and keeps deployed code on success", %{
    targets: targets
  } do
    target = targets.upgrade
    write_source(target, :v1)
    Code.compile_file(target.source_path)

    File.write!(
      target.test_path,
      module_test_code(target, "assert value(target_module()) == :v2")
    )

    write_source(target, :v2)

    assert %{status: :deployed, release_id: release_id, rollback_available: true} =
             Deployer.deploy("phase10d success", [target.source_path])

    assert is_binary(release_id)
    assert value(target.module) == :v2

    assert {:ok, release} = ReleaseStore.load_release(release_id)
    assert release["reason"] == "phase10d success"
    assert module_name(target.module) in release["modules"]

    assert Enum.any?(
             release["tests"],
             &(Map.get(&1, "path") == target.test_path or Map.get(&1, :path) == target.test_path)
           )
  end

  test "self_update status surfaces current release and related test paths", %{targets: targets} do
    target = targets.upgrade
    write_source(target, :v1)
    Code.compile_file(target.source_path)

    File.write!(
      target.test_path,
      module_test_code(target, "assert value(target_module()) == :v2")
    )

    write_source(target, :v2)

    assert %{status: :deployed, release_id: release_id} =
             Deployer.deploy("status target", [target.source_path])

    assert %{
             status: :ok,
             plan_source: :explicit,
             current_effective_release: ^release_id,
             current_event_release: ^release_id,
             previous_rollback_target: nil,
             pending_files: [pending_file],
             modules: [module_name],
             related_tests: [related_test],
             rollback_candidates: [],
             deployable: true,
             blocked_reasons: []
           } = Deployer.status([target.source_path])

    assert pending_file == Path.relative_to(target.source_path, @repo_root)
    assert module_name == target.module_name
    assert related_test == target.test_path
  end

  test "self_update history returns newest release first", %{targets: targets} do
    target = targets.upgrade
    write_source(target, :v1)
    Code.compile_file(target.source_path)

    File.write!(
      target.test_path,
      module_test_code(target, "assert value(target_module()) in [:v2, :v3]")
    )

    write_source(target, :v2)

    assert %{status: :deployed, release_id: release_v2} =
             Deployer.deploy("history v2", [target.source_path])

    write_source(target, :v3)

    assert %{status: :deployed, release_id: release_v3} =
             Deployer.deploy("history v3", [target.source_path])

    assert %{
             status: :ok,
             current_effective_release: ^release_v3,
             releases: [%{id: ^release_v3, effective: true}, %{id: ^release_v2} | _]
           } = Deployer.history()
  end

  test "self_update deploy fails syntax check before snapshotting", %{targets: targets} do
    target = targets.upgrade
    File.write!(target.source_path, "defmodule #{target.module_name} do\n  def value( do\nend\n")

    assert %{
             status: :failed,
             phase: :syntax,
             rolled_back: false,
             restored_files: [],
             runtime_restored: :none,
             error: error
           } = Deployer.deploy("syntax fail", [target.source_path])

    assert error =~ "Syntax check failed"
    assert File.read!(target.source_path) =~ "def value( do"

    assert [event] = EventStore.recent(5)
    assert event["name"] == "self_update.deploy.failed"
    assert event["classifier"]["deploy_phase"] == "syntax"
    assert event["evidence"]["self_update_error_summary"] =~ "Syntax check failed"
  end

  test "self_update deploy restores tracked file after compile failure", %{targets: targets} do
    target = targets.upgrade
    write_source(target, :v1)
    Code.compile_file(target.source_path)

    File.write!(
      target.test_path,
      module_test_code(target, "assert value(target_module()) == :v2")
    )

    write_source(target, :v2)

    assert %{status: :deployed} =
             Deployer.deploy("stable release before compile failure", [target.source_path])

    File.write!(
      target.source_path,
      """
      defmodule #{target.module_name} do
        raise "compile boom"
        def value, do: :bad
      end
      """
    )

    assert %{
             status: :failed,
             phase: :compile,
             rolled_back: true,
             restored_files: [restored_file],
             runtime_restored: runtime_restored,
             error: error
           } = Deployer.deploy("compile fail", [target.source_path])

    assert restored_file == Path.relative_to(target.source_path, @repo_root)
    assert runtime_restored in [:best_effort, :none]
    assert error =~ "compile boom"
    assert File.read!(target.source_path) =~ "def value, do: :v2"
  end

  test "self_update rollback restores the previous release snapshot", %{targets: targets} do
    target = targets.rollback
    write_source(target, :good)
    Code.compile_file(target.source_path)

    File.write!(
      target.test_path,
      module_test_code(target, "assert value(target_module()) in [:v2, :good]")
    )

    write_source(target, :v2)

    assert %{status: :deployed, release_id: _release_id} =
             Deployer.deploy("deploy v2", [target.source_path])

    assert value(target.module) == :v2

    assert %{status: :rolled_back, target_release_id: nil} = Deployer.rollback("previous")
    assert File.read!(target.source_path) =~ "def value, do: :good"

    :code.purge(target.module)
    :code.delete(target.module)
    Code.compile_file(target.source_path)
    assert value(target.module) == :good
    assert %{"status" => "rolled_back"} = ReleaseStore.current_release()
  end

  test "self_update rollback to an explicit release restores that release state", %{
    targets: targets
  } do
    target = targets.rollback
    write_source(target, :good)
    Code.compile_file(target.source_path)

    File.write!(
      target.test_path,
      module_test_code(target, "assert value(target_module()) in [:good, :v2, :v3]")
    )

    write_source(target, :v2)

    assert %{status: :deployed, release_id: release_v2} =
             Deployer.deploy("deploy v2", [target.source_path])

    write_source(target, :v3)
    assert %{status: :deployed} = Deployer.deploy("deploy v3", [target.source_path])

    assert %{status: :rolled_back, target_release_id: ^release_v2} =
             Deployer.rollback(release_v2)

    :code.purge(target.module)
    :code.delete(target.module)
    Code.compile_file(target.source_path)
    assert value(target.module) == :v2
  end

  test "self_update rollback previous follows the restored release lineage", %{targets: targets} do
    target = targets.rollback
    write_source(target, :good)
    Code.compile_file(target.source_path)

    File.write!(
      target.test_path,
      module_test_code(target, "assert value(target_module()) in [:good, :v2, :v3]")
    )

    write_source(target, :v2)

    assert %{status: :deployed, release_id: release_v2} =
             Deployer.deploy("deploy v2", [target.source_path])

    write_source(target, :v3)
    assert %{status: :deployed} = Deployer.deploy("deploy v3", [target.source_path])

    assert %{status: :rolled_back, target_release_id: ^release_v2} =
             Deployer.rollback("previous")

    assert %{status: :rolled_back, target_release_id: nil} = Deployer.rollback("previous")

    :code.purge(target.module)
    :code.delete(target.module)
    Code.compile_file(target.source_path)
    assert value(target.module) == :good
  end

  test "self_update rollback rejects missing release ids" do
    assert %{
             status: :failed,
             phase: :plan,
             rolled_back: false,
             runtime_restored: :none,
             error: "Rollback target release not found: missing-release"
           } = Deployer.rollback("missing-release")
  end

  test "self_update rollback rejects the current effective release", %{targets: targets} do
    target = targets.rollback
    write_source(target, :good)
    Code.compile_file(target.source_path)

    File.write!(
      target.test_path,
      module_test_code(target, "assert value(target_module()) == :v2")
    )

    write_source(target, :v2)

    assert %{status: :deployed, release_id: release_v2} =
             Deployer.deploy("deploy v2", [target.source_path])

    assert %{
             status: :failed,
             phase: :plan,
             rolled_back: false,
             runtime_restored: :none,
             error: "Already at target release: " <> ^release_v2
           } = Deployer.rollback(release_v2)
  end

  test "self_update rollback restores current code when rollback tests fail", %{targets: targets} do
    target = targets.rollback
    write_source(target, :good)
    Code.compile_file(target.source_path)

    File.write!(
      target.test_path,
      module_test_code(target, "assert value(target_module()) in [:v2, :v3]")
    )

    write_source(target, :v2)

    assert %{status: :deployed, release_id: release_v2} =
             Deployer.deploy("deploy v2", [target.source_path])

    write_source(target, :v3)
    assert %{status: :deployed} = Deployer.deploy("deploy v3", [target.source_path])

    File.write!(
      target.test_path,
      module_test_code(target, "assert value(target_module()) == :v3")
    )

    assert %{
             status: :failed,
             phase: :tests,
             rolled_back: true,
             restored_files: [restored_file],
             warnings: ["Rollback target restore failed"],
             runtime_restored: runtime_restored
           } = Deployer.rollback(release_v2)

    assert restored_file == Path.relative_to(target.source_path, @repo_root)
    assert runtime_restored in [:best_effort, :none]
    assert File.read!(target.source_path) =~ "def value, do: :v3"

    :code.purge(target.module)
    :code.delete(target.module)
    Code.compile_file(target.source_path)
    assert value(target.module) == :v3
  end

  test "self_update deploy reports test failure for untracked files without promising snapshot restore" do
    target = untracked_target_spec("VerifiedTarget")
    File.mkdir_p!(Path.dirname(target.source_path))
    write_source(target, :good)
    Code.compile_file(target.source_path)

    File.write!(
      target.test_path,
      module_test_code(target, "assert value(target_module()) == :good")
    )

    write_source(target, :bad)

    assert %{
             status: :failed,
             phase: :tests,
             rolled_back: true,
             runtime_restored: runtime_restored
           } =
             Deployer.deploy("phase10d failure", [target.source_path])

    assert runtime_restored in [:best_effort, :none]
    assert File.read!(target.source_path) =~ "def value, do: :bad"

    File.rm_rf!(target.source_path)
    File.rm_rf!(target.test_path)
    :code.purge(target.module)
    :code.delete(target.module)
  end

  defp fresh_tool_code(module_suffix, tool_name, return_value) do
    """
    defmodule Nex.Agent.Tool.#{module_suffix} do
      @behaviour Nex.Agent.Tool.Behaviour
      def name, do: "#{tool_name}"
      def description, do: "test tool"
      def category, do: :base
      def definition do
        %{name: "#{tool_name}", description: "test", parameters: %{type: "object", properties: %{}}}
      end
      def execute(_args, _ctx), do: {:ok, "#{return_value}"}
    end
    """
  end

  defp simple_module_code(module_name, value) do
    """
    defmodule #{module_name} do
      def value, do: #{inspect(value)}
    end
    """
  end

  defp ensure_registry! do
    if Process.whereis(Registry) == nil do
      start_supervised!({Registry, name: Registry})
    end
  end

  defp wait_for_registry(tool_name, attempts \\ 20) do
    if attempts > 0 and Registry.get(tool_name) == nil do
      Process.sleep(10)
      wait_for_registry(tool_name, attempts - 1)
    else
      :ok
    end
  end

  defp unregister_test_tools do
    Registry.unregister("hot_reload_test")
    Registry.unregister("swap_test")
    Process.sleep(20)
  end

  defp purge_test_modules(targets) do
    test_modules = [
      Nex.Agent.Tool.HotReloadTestTool,
      Nex.Agent.Tool.SwapTestTool
      | Enum.map(Map.values(targets), & &1.module)
    ]

    for mod <- test_modules do
      :code.purge(mod)
      :code.delete(mod)
    end
  end

  defp self_update_artifacts do
    root = ReleaseStore.root_dir()

    if File.dir?(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  defp remove_new_artifacts(existing_artifacts) do
    self_update_artifacts()
    |> MapSet.difference(existing_artifacts)
    |> Enum.each(&File.rm_rf!/1)
  end

  defp tracked_target_spec(base) do
    module_name = "Nex.Agent.Test.#{base}"

    %{
      module: Module.concat([module_name]),
      module_name: module_name,
      source_path: tracked_source_path(base),
      test_path: tracked_test_path(base),
      original_source: File.read!(tracked_source_path(base)),
      original_test: File.read!(tracked_test_path(base))
    }
  end

  defp untracked_target_spec(base) do
    module_name = "Nex.Agent.Test.#{base}"

    %{
      module: Module.concat([module_name]),
      module_name: module_name,
      source_path: tracked_source_path(base),
      test_path: tracked_test_path(base)
    }
  end

  defp value(module), do: apply(module, :value, [])

  defp write_source(target, value) do
    File.write!(target.source_path, simple_module_code(target.module_name, value))
  end

  defp module_test_code(target, assertion) do
    """
    defmodule #{module_name(target.module)}Test do
      use ExUnit.Case, async: false

      defp target_module, do: #{module_name(target.module)}
      defp value(module), do: apply(module, :value, [])

      test "value" do
        #{assertion}
      end
    end
    """
  end

  defp restore_tracked_sources(targets) do
    Enum.each(Map.values(targets), fn target ->
      File.write!(target.source_path, target.original_source)
      File.write!(target.test_path, target.original_test)
    end)
  end

  defp tracked_source_path(base) do
    Path.join(@repo_root, "lib/nex/agent/test/#{Macro.underscore(base)}.ex")
  end

  defp tracked_test_path(base) do
    Path.join(@repo_root, "test/nex/agent/test/#{Macro.underscore(base)}_test.exs")
  end

  defp module_name(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end
end
