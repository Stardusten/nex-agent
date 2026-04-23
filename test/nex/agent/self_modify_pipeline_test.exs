defmodule Nex.Agent.SelfModifyPipelineTest do
  @moduledoc """
  Phase 0 验证：agent 自修改管线端到端测试。

  覆盖链路：read code → modify code → hot-reload → rollback

  ## 手工 E2E 测试（gateway 运行时）

  1. 启动 gateway: `MIX_ENV=dev mise exec -- mix nex.agent gateway --log`
  2. 在任意 channel 发送：「用 reflect tool 查看 Nex.Agent.Tool.Reflect 的源码」
  3. 发送：「用 upgrade_code 修改 Reflect 模块，在 evolution_status action 的输出开头加一行 "[self-modify test ok]"，reason 填 "phase0 e2e test"」
  4. 发送：「再用 reflect 查看 evolution_status」
  5. 验证输出开头出现 "[self-modify test ok]"
  6. 发送：「用 reflect 的 versions action 查看 Nex.Agent.Tool.Reflect 的版本历史」
  7. 验证有刚才的版本记录
  8. 手动 `git checkout lib/nex/agent/tool/reflect.ex` 恢复原始代码
  """

  use ExUnit.Case, async: false

  alias Nex.Agent.{CodeUpgrade, HotReload}
  alias Nex.Agent.Tool.Registry

  @tmp_prefix "nex-selfmod-test"

  setup do
    tmp = Path.join(System.tmp_dir!(), "#{@tmp_prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    prev_upgrades = Application.get_env(:nex_agent, :code_upgrades_path)
    upgrades_dir = Path.join(tmp, "code_upgrades")
    File.mkdir_p!(upgrades_dir)
    Application.put_env(:nex_agent, :code_upgrades_path, upgrades_dir)

    on_exit(fn ->
      if prev_upgrades do
        Application.put_env(:nex_agent, :code_upgrades_path, prev_upgrades)
      else
        Application.delete_env(:nex_agent, :code_upgrades_path)
      end

      purge_test_modules()
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, upgrades_dir: upgrades_dir}
  end

  # ── Test 1: HotReload 编译加载全新模块 ──

  test "hot_reload compiles and loads a new module from source", %{tmp: tmp} do
    source_path = Path.join(tmp, "hot_reload_test_tool.ex")
    code = fresh_tool_code("HotReloadTestTool", "hot_reload_test", "hello from hot reload")
    File.write!(source_path, code)

    result = HotReload.reload(source_path, code)

    assert result.reload_succeeded == true
    assert result.restart_required == false
    assert result.module == "Nex.Agent.Tool.HotReloadTestTool"

    module = Nex.Agent.Tool.HotReloadTestTool
    assert {:ok, "hello from hot reload"} = module.execute(%{}, %{})
  end

  # ── Test 2: HotReload + Registry hot-swap ──

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

  # ── Test 3: CodeUpgrade 完整升级 + 版本管理 + 回滚 ──

  test "code_upgrade upgrades, versions, and rolls back a module", %{tmp: tmp} do
    source_path = Path.join(tmp, "upgrade_target.ex")
    v1_code = simple_module_code("UpgradeTarget", :v1)
    File.write!(source_path, v1_code)
    Code.compile_string(v1_code)

    v2_code = simple_module_code("UpgradeTarget", :v2)

    assert {:ok, %{version: version, hot_reload: hr}} =
             CodeUpgrade.upgrade_module(Nex.Agent.Test.UpgradeTarget, v2_code)

    assert hr.reload_succeeded
    assert version.id |> is_binary()
    assert Nex.Agent.Test.UpgradeTarget.value() == :v2

    versions = CodeUpgrade.list_versions(Nex.Agent.Test.UpgradeTarget)
    assert length(versions) >= 1

    v3_code = simple_module_code("UpgradeTarget", :v3)
    assert {:ok, _} = CodeUpgrade.upgrade_module(Nex.Agent.Test.UpgradeTarget, v3_code)
    assert Nex.Agent.Test.UpgradeTarget.value() == :v3

    assert :ok = CodeUpgrade.rollback(Nex.Agent.Test.UpgradeTarget)
    assert Nex.Agent.Test.UpgradeTarget.value() == :v2
  end

  # ── Test 4: 语法错误自动回滚 ──

  test "code_upgrade auto-rolls back on syntax error", %{tmp: tmp} do
    source_path = Path.join(tmp, "rollback_target.ex")
    good_code = simple_module_code("RollbackTarget", :good)
    File.write!(source_path, good_code)
    Code.compile_string(good_code)

    assert {:ok, _} = CodeUpgrade.upgrade_module(Nex.Agent.Test.RollbackTarget, good_code)
    assert Nex.Agent.Test.RollbackTarget.value() == :good

    bad_code = """
    defmodule Nex.Agent.Test.RollbackTarget do
      def value, do: :bad
      # missing end
    """

    assert {:error, reason} = CodeUpgrade.upgrade_module(Nex.Agent.Test.RollbackTarget, bad_code)
    assert reason =~ "Validation failed"
    assert Nex.Agent.Test.RollbackTarget.value() == :good
  end

  # ── Test 5: UpgradeCode tool 接口 ──

  test "upgrade_code tool executes a full self-modify cycle", %{tmp: tmp} do
    ensure_registry!()
    ensure_upgrade_manager!()

    source_path = Path.join(tmp, "tool_upgrade_target.ex")
    v1_code = fresh_tool_code("ToolUpgradeTarget", "tool_upgrade_target", "before")
    File.write!(source_path, v1_code)
    HotReload.reload(source_path, v1_code)
    wait_for_registry("tool_upgrade_target")

    v2_code = fresh_tool_code("ToolUpgradeTarget", "tool_upgrade_target", "after")

    result =
      Nex.Agent.Tool.UpgradeCode.execute(
        %{
          "module" => "Nex.Agent.Tool.ToolUpgradeTarget",
          "code" => v2_code,
          "reason" => "phase0 test"
        },
        %{}
      )

    assert {:ok, %{message: msg}} = result
    assert msg =~ "upgraded"
    assert msg =~ "phase0 test"

    wait_for_registry("tool_upgrade_target")
    assert {:ok, "after"} = Registry.execute("tool_upgrade_target", %{}, %{})
  end

  # ── Helpers ──

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

  defp simple_module_code(module_suffix, value) do
    """
    defmodule Nex.Agent.Test.#{module_suffix} do
      def value, do: #{inspect(value)}
    end
    """
  end

  defp ensure_registry! do
    if Process.whereis(Registry) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
      start_supervised!({Registry, name: Registry})
    end
  end

  defp ensure_upgrade_manager! do
    if Process.whereis(Nex.Agent.UpgradeManager) == nil do
      start_supervised!({Nex.Agent.UpgradeManager, []})
    end
  end

  defp wait_for_registry(tool_name, attempts \\ 20) do
    if attempts > 0 and Registry.get(tool_name) == nil do
      Process.sleep(10)
      wait_for_registry(tool_name, attempts - 1)
    end
  end

  defp purge_test_modules do
    test_modules = [
      Nex.Agent.Tool.HotReloadTestTool,
      Nex.Agent.Tool.SwapTestTool,
      Nex.Agent.Tool.ToolUpgradeTarget,
      Nex.Agent.Test.UpgradeTarget,
      Nex.Agent.Test.RollbackTarget
    ]

    for mod <- test_modules do
      :code.purge(mod)
      :code.delete(mod)
    end
  end
end
