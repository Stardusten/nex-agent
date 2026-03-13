defmodule Nex.Agent.ToolCreateValidationTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.CustomTools

  setup do
    root =
      Path.join(System.tmp_dir!(), "nex-agent-custom-tools-#{System.unique_integer([:positive])}")

    Application.put_env(:nex_agent, :custom_tools_path, root)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :custom_tools_path)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "custom tool must declare behaviour" do
    source = """
    defmodule Nex.Agent.Tool.Custom.NoBehaviour do
      def name, do: "no_behaviour"
      def description, do: "test"
      def category, do: :base

      def definition do
        %{name: name(), description: description(), parameters: %{type: "object", properties: %{}, required: []}}
      end

      def execute(_args, _ctx), do: {:ok, "ok"}
    end
    """

    assert {:error, reason} =
             CustomTools.create("no_behaviour", "tool without behaviour", source,
               created_by: "test"
             )

    assert reason =~ "declare @behaviour Nex.Agent.Tool.Behaviour"
  end
end
