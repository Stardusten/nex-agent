defmodule Nex.Agent.Workbench.StoreTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Workbench.{AppManifest, Store}
  alias Nex.Agent.Workspace

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-workbench-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "workspace ensure creates the workbench directory", %{workspace: workspace} do
    assert "workbench" in Workspace.known_dirs()

    Workspace.ensure!(workspace: workspace)

    assert File.dir?(Path.join(workspace, "workbench"))
    assert Workspace.workbench_dir(workspace: workspace) == Path.join(workspace, "workbench")
  end

  test "saves, lists, and gets normalized manifests", %{workspace: workspace} do
    assert {:ok, %AppManifest{} = manifest} =
             Store.save(
               %{
                 "id" => "stock-dashboard",
                 "title" => "Stocks",
                 "permissions" => [
                   "tools:call:stock_quote",
                   "observe:read",
                   "observe:read"
                 ]
               },
               workspace: workspace
             )

    assert manifest.id == "stock-dashboard"
    assert manifest.version == "0.1.0"
    assert manifest.entry == "index.html"
    assert manifest.permissions == ["tools:call:stock_quote", "observe:read"]
    assert File.exists?(Store.manifest_path("stock-dashboard", workspace: workspace))

    assert [%AppManifest{id: "stock-dashboard", title: "Stocks"}] =
             Store.list(workspace: workspace)

    assert {:ok, %AppManifest{entry: "index.html"}} =
             Store.get("stock-dashboard", workspace: workspace)
  end

  test "ignores legacy runtime fields without requiring them", %{workspace: workspace} do
    assert {:ok, manifest} =
             Store.save(
               %{
                 "id" => "legacy-app",
                 "title" => "Legacy",
                 "runtime" => %{"kind" => "other", "sandbox" => "other"},
                 "entry" => "index.html"
               },
               workspace: workspace
             )

    refute Map.has_key?(AppManifest.to_map(manifest), "runtime")
  end

  test "lists manifests in id order", %{workspace: workspace} do
    assert {:ok, _} =
             Store.save(
               %{"id" => "zeta-app", "title" => "Zeta", "entry" => "src/App.tsx"},
               workspace: workspace
             )

    assert {:ok, _} =
             Store.save(
               %{"id" => "alpha-app", "title" => "Alpha", "entry" => "src/App.tsx"},
               workspace: workspace
             )

    assert ["alpha-app", "zeta-app"] =
             workspace
             |> then(&Store.list(workspace: &1))
             |> Enum.map(& &1.id)
  end

  test "rejects invalid ids and escaping entries", %{workspace: workspace} do
    assert {:error, "id must match" <> _} =
             Store.save(
               %{"id" => "../bad", "title" => "Bad", "entry" => "src/App.tsx"},
               workspace: workspace
             )

    assert {:error, "entry must not contain .. segments"} =
             Store.save(
               %{"id" => "bad-app", "title" => "Bad", "entry" => "../App.tsx"},
               workspace: workspace
             )

    assert {:error, "entry must be a relative path"} =
             Store.save(
               %{"id" => "bad-app", "title" => "Bad", "entry" => "/tmp/App.tsx"},
               workspace: workspace
             )

    assert {:error, "entry is required"} =
             Store.save(
               %{"id" => "bad-app", "title" => "Bad", "entry" => ""},
               workspace: workspace
             )
  end

  test "load_all reports invalid manifests without hiding valid apps", %{workspace: workspace} do
    assert {:ok, _} =
             Store.save(
               %{"id" => "notes", "title" => "Notes", "entry" => "src/App.tsx"},
               workspace: workspace
             )

    invalid_json_dir = Path.join([workspace, "workbench", "apps", "broken-json"])
    invalid_shape_dir = Path.join([workspace, "workbench", "apps", "broken-shape"])
    missing_manifest_dir = Path.join([workspace, "workbench", "apps", "missing-manifest"])

    File.mkdir_p!(invalid_json_dir)
    File.mkdir_p!(invalid_shape_dir)
    File.mkdir_p!(missing_manifest_dir)
    File.write!(Path.join(invalid_json_dir, "nex.app.json"), "{not json")

    File.write!(
      Path.join(invalid_shape_dir, "nex.app.json"),
      Jason.encode!(%{"id" => "wrong-id", "title" => "", "entry" => "src/App.tsx"})
    )

    assert %{"apps" => [%AppManifest{id: "notes"}], "diagnostics" => diagnostics} =
             Store.load_all(workspace: workspace)

    assert length(diagnostics) == 3
    assert Enum.any?(diagnostics, &(&1["app_id"] == "broken-json"))
    assert Enum.any?(diagnostics, &(&1["app_id"] == "broken-shape"))
    assert Enum.any?(diagnostics, &(&1["app_id"] == "missing-manifest"))
  end
end
