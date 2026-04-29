defmodule Nex.Agent.Extension.Plugin.CatalogTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.{Runtime.Config, Extension.Plugin}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-plugin-catalog-#{System.unique_integer([:positive])}"
      )

    builtin = Path.join(tmp, "builtin")
    workspace = Path.join(tmp, "workspace")

    File.mkdir_p!(builtin)
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, builtin: builtin, workspace_plugins_dir: workspace}
  end

  test "projects enabled manifests and normalized contributions", %{
    builtin: builtin,
    workspace_plugins_dir: workspace_plugins_dir
  } do
    write_manifest(builtin, "tool.web", %{
      "id" => "builtin:tool.web",
      "title" => "Web Tools",
      "source" => "builtin",
      "contributes" => %{
        "tools" => [%{"name" => "web_search", "module" => "Nex.Agent.Tool.WebSearch"}]
      }
    })

    data =
      Plugin.runtime_data(
        builtin_plugins_dir: builtin,
        workspace_plugins_dir: workspace_plugins_dir
      )

    assert data.enabled == ["builtin:tool.web"]

    assert [
             %{
               "id" => "web_search",
               "plugin_id" => "builtin:tool.web",
               "plugin_root" => plugin_root
             }
           ] =
             data.contributions["tools"]

    assert plugin_root == Path.join(builtin, "tool.web")
    assert is_binary(data.hash)
  end

  test "disabled always wins over enabled", %{
    builtin: builtin,
    workspace_plugins_dir: workspace_plugins_dir
  } do
    write_manifest(builtin, "tool.web", %{
      "id" => "builtin:tool.web",
      "title" => "Web Tools",
      "source" => "builtin",
      "contributes" => %{"tools" => [%{"name" => "web_search"}]}
    })

    config =
      Config.from_map(%{
        "plugins" => %{
          "disabled" => ["builtin:tool.web"],
          "enabled" => %{"builtin:tool.web" => true}
        }
      })

    data =
      Plugin.runtime_data(
        config: config,
        builtin_plugins_dir: builtin,
        workspace_plugins_dir: workspace_plugins_dir
      )

    assert data.enabled == []
    assert data.contributions["tools"] == []
    assert Enum.any?(data.diagnostics, &(&1["code"] == "plugin_enablement_conflict"))
  end

  test "workspace plugins require config enablement", %{
    builtin: builtin,
    workspace_plugins_dir: workspace_plugins_dir
  } do
    write_manifest(workspace_plugins_dir, "notes", %{
      "id" => "workspace:notes",
      "title" => "Notes",
      "source" => "workspace",
      "contributes" => %{"skills" => [%{"id" => "workspace:notes"}]}
    })

    disabled =
      Plugin.runtime_data(
        builtin_plugins_dir: builtin,
        workspace_plugins_dir: workspace_plugins_dir
      )

    assert disabled.enabled == []

    config = Config.from_map(%{"plugins" => %{"enabled" => %{"workspace:notes" => true}}})

    enabled =
      Plugin.runtime_data(
        config: config,
        builtin_plugins_dir: builtin,
        workspace_plugins_dir: workspace_plugins_dir
      )

    assert enabled.enabled == ["workspace:notes"]
    assert [%{"id" => "workspace:notes"}] = enabled.contributions["skills"]
  end

  test "deferred contribution kinds produce diagnostics and no active contribution", %{
    builtin: builtin,
    workspace_plugins_dir: workspace_plugins_dir
  } do
    write_manifest(builtin, "workbench.sessions", %{
      "id" => "builtin:workbench.sessions",
      "title" => "Sessions",
      "source" => "builtin",
      "contributes" => %{"workbench_views" => [%{"id" => "sessions"}]}
    })

    data =
      Plugin.runtime_data(
        builtin_plugins_dir: builtin,
        workspace_plugins_dir: workspace_plugins_dir
      )

    refute Map.has_key?(data.contributions, "workbench_views")
    assert Enum.any?(data.diagnostics, &(&1["code"] == "deferred_contribution_kind"))
  end

  test "migrated catalogs do not emit inventory diagnostics", %{
    builtin: builtin,
    workspace_plugins_dir: workspace_plugins_dir
  } do
    data =
      Plugin.runtime_data(
        builtin_plugins_dir: builtin,
        workspace_plugins_dir: workspace_plugins_dir
      )

    refute Enum.any?(data.diagnostics, &(&1["kind"] == "inventory"))
  end

  defp write_manifest(root, name, attrs) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "nex.plugin.json"), Jason.encode!(attrs))
  end
end
