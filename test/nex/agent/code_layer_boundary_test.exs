defmodule Nex.Agent.CodeLayerBoundaryTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.CodeUpgrade
  alias Nex.Agent.SelfUpdate.Planner
  alias Nex.Agent.Tool.Reflect

  test "code_layer_file excludes workspace custom tool paths" do
    refute CodeUpgrade.code_layer_file?("/tmp/workspace/tools/weather_shenzhen/tool.ex")
  end

  test "planner rejects non-code-layer files" do
    tmp_file =
      Path.join(System.tmp_dir!(), "outside-self-update-#{System.unique_integer([:positive])}.ex")

    File.write!(tmp_file, "defmodule OutsideSelfUpdate do\nend\n")

    on_exit(fn -> File.rm(tmp_file) end)

    assert {:error, msg} = Planner.plan([tmp_file])
    assert msg =~ "Only repo CODE-layer files"
  end

  test "reflect rejects source inspection for custom tool modules" do
    assert {:error, msg} =
             Reflect.execute(
               %{"action" => "source", "module" => "Nex.Agent.Tool.Custom.WeatherShenzhen"},
               %{}
             )

    assert msg =~ "CODE-layer framework modules"
  end

  test "reflect introspect reports source path, public API, dependencies, and dependents" do
    assert {:ok, report} =
             Reflect.execute(%{"action" => "introspect", "module" => "Nex.Agent.Runner"}, %{})

    assert report =~ "## Module Introspection: Nex.Agent.Runner"
    assert report =~ "lib/nex/agent/runner.ex"
    assert report =~ "- run/3"
    assert report =~ "- Nex.Agent.ContextBuilder"
    assert report =~ "- Nex.Agent.Session"
    assert report =~ "- Nex.Agent"
    assert report =~ "Hot-loaded code affects future calls"
  end

  test "reflect rejects custom tool module introspection" do
    assert {:error, msg} =
             Reflect.execute(
               %{"action" => "introspect", "module" => "Nex.Agent.Tool.Custom.WeatherShenzhen"},
               %{}
             )

    assert msg =~ "CODE-layer framework modules"
  end

  test "reflect list_modules excludes protected modules from editable discovery" do
    assert {:ok, %{status: :ok, modules: modules}} =
             Reflect.execute(%{"action" => "list_modules"}, %{})

    protected_modules =
      modules
      |> Enum.filter(
        &(&1.module in [
            "Nex.Agent.Tool.SelfUpdate",
            "Nex.Agent.SelfUpdate.Planner",
            "Nex.Agent.SelfUpdate.Deployer"
          ])
      )

    assert protected_modules != []
    assert Enum.all?(protected_modules, &(&1.protected == true and &1.deployable == false))
  end
end
