defmodule Nex.Agent.Conversation.CommandCatalogTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Conversation.Command.Catalog
  alias Nex.Agent.{Runtime.Config, Extension.Plugin}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-command-catalog-#{System.unique_integer([:positive])}"
      )

    builtin = Path.join(tmp, "builtin")
    workspace_plugins_dir = Path.join(tmp, "workspace")

    File.mkdir_p!(builtin)
    File.mkdir_p!(workspace_plugins_dir)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, builtin: builtin, workspace_plugins_dir: workspace_plugins_dir}
  end

  test "runtime command definitions come from enabled builtin plugin contributions" do
    names = Catalog.runtime_definitions() |> Enum.map(& &1["name"])

    assert names == ~w(new stop approve deny commands status model queue btw)
  end

  test "disabled core command plugin removes slash command definitions" do
    config = Config.from_map(%{"plugins" => %{"disabled" => ["builtin:command.core"]}})

    assert Catalog.runtime_definitions(config: config) == []
  end

  test "workspace command plugin cannot bind an executable handler", %{
    builtin: builtin,
    workspace_plugins_dir: workspace_plugins_dir
  } do
    write_manifest(workspace_plugins_dir, "custom-command", %{
      "id" => "workspace:custom-command",
      "title" => "Custom Command",
      "source" => "workspace",
      "contributes" => %{
        "commands" => [
          %{
            "name" => "deploy",
            "description" => "attempt custom command",
            "usage" => "/deploy",
            "handler" => "status",
            "channels" => ["discord"]
          }
        ]
      }
    })

    config =
      Config.from_map(%{
        "plugins" => %{"enabled" => %{"workspace:custom-command" => true}}
      })

    plugins =
      Plugin.runtime_data(
        config: config,
        builtin_plugins_dir: builtin,
        workspace_plugins_dir: workspace_plugins_dir
      )

    assert plugins.enabled == ["workspace:custom-command"]
    assert Catalog.runtime_definitions(plugin_data: plugins) == []
  end

  test "unknown builtin command handler is ignored", %{
    builtin: builtin,
    workspace_plugins_dir: workspace_plugins_dir
  } do
    write_manifest(builtin, "command.bad", %{
      "id" => "builtin:command.bad",
      "title" => "Bad Command",
      "source" => "builtin",
      "contributes" => %{
        "commands" => [
          %{
            "name" => "ship",
            "description" => "unknown handler",
            "usage" => "/ship",
            "handler" => "ship"
          }
        ]
      }
    })

    plugins =
      Plugin.runtime_data(
        builtin_plugins_dir: builtin,
        workspace_plugins_dir: workspace_plugins_dir
      )

    assert plugins.enabled == ["builtin:command.bad"]
    assert Catalog.runtime_definitions(plugin_data: plugins) == []
  end

  defp write_manifest(root, name, attrs) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "nex.plugin.json"), Jason.encode!(attrs))
  end
end
