defmodule Nex.Agent.Test.RegistryOkTool do
  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "registry_ok_test"
  def description, do: "Registry lifecycle ok test"
  def category, do: :base

  def definition do
    %{name: name(), description: description(), parameters: %{type: "object", properties: %{}}}
  end

  def execute(_args, _ctx), do: {:ok, "ok"}
end

defmodule Nex.Agent.Test.RegistryCrashTool do
  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "registry_crash_test"
  def description, do: "Registry lifecycle crash test"
  def category, do: :base

  def definition do
    %{name: name(), description: description(), parameters: %{type: "object", properties: %{}}}
  end

  def execute(_args, _ctx), do: raise("registry boom")
end

defmodule Nex.Agent.Test.RegistrySlowTool do
  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "registry_slow_test"
  def description, do: "Registry lifecycle cancellation test"
  def category, do: :base

  def definition do
    %{name: name(), description: description(), parameters: %{type: "object", properties: %{}}}
  end

  def execute(_args, _ctx) do
    Process.sleep(5_000)
    {:ok, "late"}
  end
end

defmodule Nex.Agent.ToolRegistryTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.ControlPlane.Query, as: ControlPlaneQuery
  alias Nex.Agent.Tool.Registry

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-registry-#{System.unique_integer([:positive])}"
      )

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Registry) == nil do
      start_supervised!({Registry, name: Registry})
    end

    Registry.register(Nex.Agent.Test.RegistryOkTool)
    Registry.register(Nex.Agent.Test.RegistryCrashTool)
    Registry.register(Nex.Agent.Test.RegistrySlowTool)
    wait_for_tool("registry_ok_test")
    wait_for_tool("registry_crash_test")
    wait_for_tool("registry_slow_test")

    on_exit(fn ->
      Registry.unregister("registry_ok_test")
      Registry.unregister("registry_crash_test")
      Registry.unregister("registry_slow_test")
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "execute/3 records started and finished observations", %{workspace: workspace} do
    assert {:ok, "ok"} =
             Registry.execute("registry_ok_test", %{"token" => "secret"}, %{
               workspace: workspace,
               run_id: "run_registry_ok",
               tool_call_id: "call_registry_ok"
             })

    assert [started] =
             observations(workspace, tag: "tool.registry.execute.started")

    assert started["context"]["run_id"] == "run_registry_ok"
    assert started["context"]["tool_call_id"] == "call_registry_ok"
    assert started["attrs"]["tool_name"] == "registry_ok_test"
    refute inspect(started) =~ "secret"

    assert [finished] =
             observations(workspace, tag: "tool.registry.execute.finished")

    assert finished["attrs"]["result_status"] == "ok"
  end

  test "execute/3 records failed observations for tool exceptions", %{workspace: workspace} do
    assert {:error, reason} =
             Registry.execute("registry_crash_test", %{}, %{
               workspace: workspace,
               run_id: "run_registry_crash",
               tool_call_id: "call_registry_crash"
             })

    assert reason =~ "crashed"

    assert [failed] =
             observations(workspace, tag: "tool.registry.execute.failed")

    assert failed["context"]["run_id"] == "run_registry_crash"
    assert failed["attrs"]["tool_name"] == "registry_crash_test"
    assert failed["attrs"]["result_status"] == "error"
  end

  test "cancel_run/1 records cancelled observation and replies to execute caller", %{
    workspace: workspace
  } do
    parent = self()

    task =
      Task.async(fn ->
        result =
          Registry.execute("registry_slow_test", %{}, %{
            workspace: workspace,
            run_id: "run_registry_cancel",
            tool_call_id: "call_registry_cancel"
          })

        send(parent, {:registry_cancel_result, result})
        result
      end)

    assert eventually(fn ->
             observations(workspace, tag: "tool.registry.execute.started") != []
           end)

    assert :ok = Registry.cancel_run("run_registry_cancel")
    assert_receive {:registry_cancel_result, {:error, reason}}, 1_000
    assert reason =~ "cancelled"
    Task.shutdown(task, :brutal_kill)

    assert [cancelled] =
             observations(workspace, tag: "tool.registry.execute.cancelled")

    assert cancelled["context"]["run_id"] == "run_registry_cancel"
    assert cancelled["attrs"]["result_status"] == "cancelled"
  end

  test "execute/3 owns timeout and records timeout observation", %{workspace: workspace} do
    assert {:error, reason} =
             Registry.execute("registry_slow_test", %{}, %{
               workspace: workspace,
               run_id: "run_registry_timeout",
               tool_call_id: "call_registry_timeout",
               timeout: 25
             })

    assert reason =~ "timed out"

    assert eventually(fn ->
             observations(workspace, tag: "tool.registry.execute.timeout") != []
           end)

    assert [timeout] = observations(workspace, tag: "tool.registry.execute.timeout")

    assert timeout["context"]["run_id"] == "run_registry_timeout"
    assert timeout["context"]["tool_call_id"] == "call_registry_timeout"
    assert timeout["attrs"]["tool_name"] == "registry_slow_test"
    assert timeout["attrs"]["result_status"] == "timeout"
    assert timeout["attrs"]["reason_type"] == "timeout"
  end

  defp observations(workspace, filters) do
    filters
    |> Map.new()
    |> ControlPlaneQuery.query(workspace: workspace)
  end

  defp wait_for_tool(name, attempts \\ 20)
  defp wait_for_tool(_name, 0), do: :ok

  defp wait_for_tool(name, attempts) do
    if Registry.get(name) do
      :ok
    else
      Process.sleep(10)
      wait_for_tool(name, attempts - 1)
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
