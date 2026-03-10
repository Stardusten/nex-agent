defmodule Nex.Agent.CustomToolsTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Evolution
  alias Nex.Agent.Tool.CustomTools
  alias Nex.Agent.Tool.Registry
  alias Nex.Agent.Tool.ToolCreate
  alias Nex.Agent.Tool.ToolDelete
  alias Nex.Agent.Tool.ToolList

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "nex_agent_custom_tools_test_#{System.unique_integer([:positive])}")
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

  test "tool_create creates, registers, lists, and deletes a custom tool", %{custom_tools_dir: custom_tools_dir} do
    code = """
    defmodule Nex.Agent.Tool.Custom.HelloTool do
      @behaviour Nex.Agent.Tool.Behaviour

      def name, do: "hello_tool"
      def description, do: "Say hello"
      def category, do: :base

      def definition do
        %{
          name: name(),
          description: description(),
          parameters: %{
            type: "object",
            properties: %{
              name: %{type: "string", description: "Name to greet"}
            }
          }
        }
      end

      def execute(%{"name" => name}, _ctx), do: {:ok, "hello \#{name}"}
      def execute(_args, _ctx), do: {:ok, "hello"}
    end
    """

    assert {:ok, %{tool: tool}} =
             ToolCreate.execute(
               %{"name" => "hello_tool", "description" => "Say hello", "content" => code},
               %{}
             )

    assert tool["name"] == "hello_tool"
    assert File.exists?(Path.join([custom_tools_dir, "hello_tool", "tool.ex"]))
    assert File.exists?(Path.join([custom_tools_dir, "hello_tool", "tool.json"]))
    assert Registry.get("hello_tool") == Nex.Agent.Tool.Custom.HelloTool
    assert Evolution.source_path(Nex.Agent.Tool.Custom.HelloTool) ==
             Path.join([custom_tools_dir, "hello_tool", "tool.ex"])

    assert {:ok, %{custom: custom}} = ToolList.execute(%{"scope" => "custom"}, %{})
    assert Enum.any?(custom, &(&1["name"] == "hello_tool"))

    assert {:ok, detail} = ToolList.execute(%{"detail" => "hello_tool"}, %{})
    assert detail["scope"] == "global"
    assert detail["module"] == "Nex.Agent.Tool.Custom.HelloTool"
    assert detail["source_path"] == Path.join([custom_tools_dir, "hello_tool", "tool.ex"])
    assert detail["created_by"] == "agent"

    assert {:ok, %{status: "deleted"}} = ToolDelete.execute(%{"name" => "hello_tool"}, %{})
    assert Registry.get("hello_tool") == nil
    refute File.exists?(Path.join([custom_tools_dir, "hello_tool"]))
  end

  test "registry discovers custom tools on startup", %{custom_tools_dir: custom_tools_dir} do
    File.mkdir_p!(Path.join(custom_tools_dir, "startup_tool"))
    File.write!(Path.join([custom_tools_dir, "startup_tool", "tool.json"]), Jason.encode!(%{
      name: "startup_tool",
      module: "Nex.Agent.Tool.Custom.StartupTool",
      description: "Loaded on startup",
      scope: "global",
      created_by: "user",
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      origin: "local"
    }))

    File.write!(Path.join([custom_tools_dir, "startup_tool", "tool.ex"]), """
    defmodule Nex.Agent.Tool.Custom.StartupTool do
      @behaviour Nex.Agent.Tool.Behaviour
      def name, do: "startup_tool"
      def description, do: "Loaded on startup"
      def category, do: :base
      def definition, do: %{name: name(), description: description(), parameters: %{type: "object", properties: %{}}}
      def execute(_args, _ctx), do: {:ok, "started"}
    end
    """)

    :ok = Registry.reload()

    assert Registry.get("startup_tool") == Nex.Agent.Tool.Custom.StartupTool
    assert Enum.member?(CustomTools.list_modules(), Nex.Agent.Tool.Custom.StartupTool)
  end

  test "tool_create rejects conflicts with built-in tools" do
    code = """
    defmodule Nex.Agent.Tool.Custom.Read do
      @behaviour Nex.Agent.Tool.Behaviour
      def name, do: "read"
      def description, do: "bad"
      def category, do: :base
      def definition, do: %{name: name(), description: description(), parameters: %{type: "object", properties: %{}}}
      def execute(_args, _ctx), do: {:ok, "bad"}
    end
    """

    assert {:error, reason} =
             ToolCreate.execute(%{"name" => "read", "description" => "bad", "content" => code}, %{})

    assert reason =~ "already exists"
  end

  test "list_modules ignores malformed metadata module names", %{custom_tools_dir: custom_tools_dir} do
    File.mkdir_p!(Path.join(custom_tools_dir, "bad_tool"))
    File.write!(Path.join([custom_tools_dir, "bad_tool", "tool.json"]), Jason.encode!(%{
      name: "bad_tool",
      module: "Totally.Unrelated.Module",
      description: "bad metadata",
      scope: "global",
      created_by: "user",
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      origin: "local"
    }))

    assert CustomTools.list_modules() == []
  end

  test "registry rejects hot swap that collides with existing built-in tool" do
    original_read = Registry.get("read")

    [{conflict_module, _binary}] =
      Code.compile_string("""
      defmodule Nex.Agent.Tool.Custom.ReadCollision do
        @behaviour Nex.Agent.Tool.Behaviour
        def name, do: "read"
        def description, do: "bad collision"
        def category, do: :base
        def definition, do: %{name: name(), description: description(), parameters: %{type: "object", properties: %{}}}
        def execute(_args, _ctx), do: {:ok, "bad"}
      end
      """)

    Registry.hot_swap("tool_list", conflict_module)
    Process.sleep(50)

    assert Registry.get("read") == original_read
    assert Registry.get("tool_list") == Nex.Agent.Tool.ToolList
  end
end
