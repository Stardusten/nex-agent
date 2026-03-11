defmodule Nex.Agent.Tool.EditWriteHotReloadTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.Edit
  alias Nex.Agent.Tool.Registry
  alias Nex.Agent.Tool.Write

  setup do
    tmp_dir =
      Path.join(["/tmp", "nex_agent_edit_write_hot_reload_#{System.unique_integer([:positive])}"])

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

    %{tmp_dir: tmp_dir, custom_tools_dir: custom_tools_dir}
  end

  test "write hot-reloads tool modules and reports registry swap status", %{
    custom_tools_dir: custom_tools_dir
  } do
    path = Path.join([custom_tools_dir, "registry_contract_tool", "tool.ex"])

    content = """
    defmodule Nex.Agent.Tool.Custom.RegistryContractTool do
      @behaviour Nex.Agent.Tool.Behaviour

      def name, do: "registry_contract_tool"
      def description, do: "Registry contract tool"
      def category, do: :base
      def definition, do: %{name: name(), description: description(), parameters: %{type: "object", properties: %{}}}
      def execute(_args, _ctx), do: {:ok, "v1"}
    end
    """

    assert {:ok,
            %{
              hot_reload: %{
                reload_attempted: true,
                reload_succeeded: true,
                activation_scope: "next_invocation_uses_new_code",
                module: "Nex.Agent.Tool.Custom.RegistryContractTool",
                restart_required: false,
                reason: nil,
                registry_swap: %{
                  attempted: true,
                  tool_name: "registry_contract_tool",
                  swapped?: true,
                  reason: nil
                }
              }
            }} =
             Write.execute(%{"path" => path, "content" => content}, %{})

    assert Registry.get("registry_contract_tool") == Nex.Agent.Tool.Custom.RegistryContractTool
  end

  test "edit hot-swaps an already registered tool and reports the settled registry state", %{
    custom_tools_dir: custom_tools_dir
  } do
    path = Path.join([custom_tools_dir, "editable_registry_tool", "tool.ex"])

    original = """
    defmodule Nex.Agent.Tool.Custom.EditableRegistryTool do
      @behaviour Nex.Agent.Tool.Behaviour

      def name, do: "editable_registry_tool"
      def description, do: "Editable registry tool"
      def category, do: :base
      def definition, do: %{name: name(), description: description(), parameters: %{type: "object", properties: %{}}}
      def execute(_args, _ctx), do: {:ok, "v1"}
    end
    """

    updated = String.replace(original, "{:ok, \"v1\"}", "{:ok, \"v2\"}")

    assert {:ok, %{hot_reload: %{registry_swap: %{swapped?: true}}}} =
             Write.execute(%{"path" => path, "content" => original}, %{})

    assert {:ok,
            %{
              hot_reload: %{
                reload_attempted: true,
                reload_succeeded: true,
                activation_scope: "next_invocation_uses_new_code",
                module: "Nex.Agent.Tool.Custom.EditableRegistryTool",
                restart_required: false,
                reason: nil,
                registry_swap: %{
                  attempted: true,
                  tool_name: "editable_registry_tool",
                  swapped?: true,
                  reason: nil
                }
              }
            }} =
             Edit.execute(
               %{
                 "path" => path,
                 "search" => "{:ok, \"v1\"}",
                 "replace" => "{:ok, \"v2\"}"
               },
               %{}
             )

    assert Registry.get("editable_registry_tool") == Nex.Agent.Tool.Custom.EditableRegistryTool
    assert {:ok, "v2"} == Nex.Agent.Tool.Custom.EditableRegistryTool.execute(%{}, %{})
    assert File.read!(path) == updated
  end

  test "write hot-reloads non-tool modules without requiring a registry swap", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "plain_runtime_module.ex")

    content = """
    defmodule Nex.Agent.HotReloadPlainRuntimeModule do
      def version, do: :plain_v1
    end
    """

    assert {:ok,
            %{
              hot_reload: %{
                reload_attempted: true,
                reload_succeeded: true,
                activation_scope: "next_invocation_uses_new_code",
                module: "Nex.Agent.HotReloadPlainRuntimeModule",
                restart_required: false,
                reason: nil,
                registry_swap: %{attempted: false, reason: :not_a_tool_module}
              }
            }} =
             Write.execute(%{"path" => path, "content" => content}, %{})

    assert Nex.Agent.HotReloadPlainRuntimeModule.version() == :plain_v1
    assert Registry.get("plain_runtime_module") == nil
  end

  test "edit returns explicit failure metadata for malformed source", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "malformed_runtime_module.ex")

    File.write!(path, """
    defmodule Nex.Agent.MalformedRuntimeModule do
      def version, do: :before
    end
    """)

    assert {:ok,
            %{
              hot_reload: %{
                reload_attempted: true,
                reload_succeeded: false,
                activation_scope: nil,
                module: "Nex.Agent.MalformedRuntimeModule",
                restart_required: true,
                reason: reason
              }
            }} =
             Edit.execute(
               %{
                 "path" => path,
                 "search" => "def version, do: :before",
                 "replace" => "def version, do:"
               },
               %{}
             )

    assert is_binary(reason)
    assert reason != ""
  end
end
