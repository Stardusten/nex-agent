defmodule Nex.Agent.Extension.Plugin.StoreTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Extension.Plugin.Store

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "nex-agent-plugin-store-#{System.unique_integer([:positive])}")

    builtin = Path.join(tmp, "builtin")
    workspace = Path.join(tmp, "workspace")

    File.mkdir_p!(builtin)
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, builtin: builtin, workspace_plugins_dir: workspace}
  end

  test "loads valid manifests and returns bounded diagnostics for invalid ones", %{
    builtin: builtin,
    workspace_plugins_dir: workspace_plugins_dir
  } do
    write_manifest(builtin, "tool.web", %{
      "id" => "builtin:tool.web",
      "title" => "Web Tools",
      "source" => "builtin",
      "contributes" => %{"tools" => [%{"name" => "web_search"}]}
    })

    broken_dir = Path.join(workspace_plugins_dir, "broken")
    File.mkdir_p!(broken_dir)
    File.write!(Path.join(broken_dir, "nex.plugin.json"), "{bad json")

    assert %{"manifests" => [manifest], "diagnostics" => [diagnostic]} =
             Store.load_all(
               builtin_plugins_dir: builtin,
               workspace_plugins_dir: workspace_plugins_dir
             )

    assert manifest.id == "builtin:tool.web"
    assert diagnostic["plugin_dir"] == "broken"
    assert diagnostic["error"] =~ "invalid JSON"
  end

  test "reports manifest id and directory mismatches", %{
    builtin: builtin,
    workspace_plugins_dir: workspace_plugins_dir
  } do
    write_manifest(builtin, "tool.web", %{
      "id" => "builtin:tool.other",
      "title" => "Other",
      "source" => "builtin"
    })

    assert %{"manifests" => [], "diagnostics" => [diagnostic]} =
             Store.load_all(
               builtin_plugins_dir: builtin,
               workspace_plugins_dir: workspace_plugins_dir
             )

    assert diagnostic["error"] =~ "does not match plugin directory"
  end

  defp write_manifest(root, name, attrs) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "nex.plugin.json"), Jason.encode!(attrs))
  end
end
