defmodule Nex.Agent.EvolutionHotReloadTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Evolution
  alias Nex.Agent.Tool.Registry

  setup do
    tmp_dir =
      Path.join(["/tmp", "nex_agent_evolution_hot_reload_#{System.unique_integer([:positive])}"])

    custom_tools_dir = Path.join(tmp_dir, "tools")

    File.mkdir_p!(custom_tools_dir)

    original_custom_tools_path = Application.get_env(:nex_agent, :custom_tools_path)
    Application.put_env(:nex_agent, :custom_tools_path, custom_tools_dir)

    unless Process.whereis(Registry), do: {:ok, _pid} = Registry.start_link(name: Registry)
    :ok = Registry.reload()

    on_exit(fn ->
      if original_custom_tools_path == nil,
        do: Application.delete_env(:nex_agent, :custom_tools_path),
        else: Application.put_env(:nex_agent, :custom_tools_path, original_custom_tools_path)

      File.rm_rf!(tmp_dir)

      if Process.whereis(Registry) do
        :ok = Registry.reload()
      end
    end)

    %{custom_tools_dir: custom_tools_dir}
  end

  test "upgrade_module returns success metadata for hot reload without requiring restart", %{
    custom_tools_dir: custom_tools_dir
  } do
    module = Nex.Agent.Tool.Custom.EvolutionContractTool
    path = Path.join([custom_tools_dir, "evolution_contract_tool", "tool.ex"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, tool_code("EvolutionContractTool", "evolution_contract_tool", "v1"))
    Code.compile_file(path)
    Registry.register(module)
    Process.sleep(50)

    assert {:ok,
            %{
              version: version,
              hot_reload: %{
                reload_attempted: true,
                reload_succeeded: true,
                activation_scope: "next_invocation_uses_new_code",
                module: "Nex.Agent.Tool.Custom.EvolutionContractTool",
                restart_required: false,
                reason: nil,
                registry_swap: %{attempted: true, tool_name: "evolution_contract_tool"}
              }
            }} =
             Evolution.upgrade_module(
               module,
               tool_code("EvolutionContractTool", "evolution_contract_tool", "v2"),
               validate: false
             )

    assert version.module == module
  end

  test "upgrade_module preserves in-flight calls and updates the next invocation", %{
    custom_tools_dir: custom_tools_dir
  } do
    module = Nex.Agent.Tool.Custom.NextInvocationTool
    path = Path.join([custom_tools_dir, "next_invocation_tool", "tool.ex"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, slow_tool_code("NextInvocationTool", "next_invocation_tool", "v1"))
    Code.compile_file(path)
    Registry.register(module)
    Process.sleep(50)

    parent = self()

    task =
      Task.async(fn ->
        module.execute(%{"parent" => parent}, %{})
      end)

    assert_receive {:entered_execute, "v1"}, 1_000

    assert {:ok,
            %{
              hot_reload: %{
                reload_attempted: true,
                reload_succeeded: true,
                activation_scope: "next_invocation_uses_new_code",
                module: "Nex.Agent.Tool.Custom.NextInvocationTool",
                restart_required: false,
                reason: nil
              }
            }} =
             Evolution.upgrade_module(
               module,
               slow_tool_code("NextInvocationTool", "next_invocation_tool", "v2"),
               validate: false
             )

    send(task.pid, :continue)

    assert {:ok, "v1"} = Task.await(task, 1_000)
    assert {:ok, "v2"} = module.execute(%{}, %{})
  end

  defp tool_code(module_suffix, tool_name, version) do
    """
    defmodule Nex.Agent.Tool.Custom.#{module_suffix} do
      @behaviour Nex.Agent.Tool.Behaviour

      def name, do: "#{tool_name}"
      def description, do: "Evolution contract tool"
      def category, do: :base
      def definition, do: %{name: name(), description: description(), parameters: %{type: "object", properties: %{}}}
      def execute(_args, _ctx), do: {:ok, "#{version}"}
    end
    """
  end

  defp slow_tool_code(module_suffix, tool_name, version) do
    """
    defmodule Nex.Agent.Tool.Custom.#{module_suffix} do
      @behaviour Nex.Agent.Tool.Behaviour

      def name, do: "#{tool_name}"
      def description, do: "Next invocation contract tool"
      def category, do: :base
      def definition, do: %{name: name(), description: description(), parameters: %{type: "object", properties: %{}}}

      def execute(%{"parent" => parent}, _ctx) do
        send(parent, {:entered_execute, "#{version}"})

        receive do
          :continue -> {:ok, "#{version}"}
        end
      end

      def execute(_args, _ctx), do: {:ok, "#{version}"}
    end
    """
  end
end
