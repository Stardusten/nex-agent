defmodule Nex.Agent.Workbench.PermissionsTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.ControlPlane.Query
  alias Nex.Agent.Workbench.{Permissions, Store}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-workbench-permissions-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "check denies by default until permission is granted", %{workspace: workspace} do
    create_notes_app!(workspace)

    assert {:error, "permission is not granted"} =
             Permissions.check("notes", "notes:read", workspace: workspace)

    assert {:ok, view} = Permissions.grant("notes", "notes:read", workspace: workspace)

    assert view["app_id"] == "notes"
    assert view["declared_permissions"] == ["notes:read", "notes:write"]
    assert view["granted_permissions"] == ["notes:read"]
    assert view["denied_permissions"] == ["notes:write"]

    assert :ok = Permissions.check("notes", "notes:read", workspace: workspace)
  end

  test "grant only accepts permissions declared by the app manifest", %{workspace: workspace} do
    create_notes_app!(workspace)

    assert {:error, "permission is not declared by app manifest"} =
             Permissions.grant("notes", "tools:call:stock_quote", workspace: workspace)

    assert {:error, "permission is not declared by app manifest"} =
             Permissions.check("notes", "tools:call:stock_quote", workspace: workspace)

    assert %{"apps" => [%{"granted_permissions" => []}], "diagnostics" => []} =
             Permissions.list(workspace: workspace)
  end

  test "revoke removes a granted permission", %{workspace: workspace} do
    create_notes_app!(workspace)

    assert {:ok, _} = Permissions.grant("notes", "notes:read", workspace: workspace)
    assert :ok = Permissions.check("notes", "notes:read", workspace: workspace)

    assert {:ok, view} = Permissions.revoke("notes", "notes:read", workspace: workspace)
    assert view["granted_permissions"] == []
    assert view["denied_permissions"] == ["notes:read", "notes:write"]

    assert {:error, "permission is not granted"} =
             Permissions.check("notes", "notes:read", workspace: workspace)
  end

  test "app view separates stale grants from effective grants", %{workspace: workspace} do
    create_notes_app!(workspace)

    assert {:ok, _} = Permissions.grant("notes", "notes:read", workspace: workspace)

    assert {:ok, _} =
             Store.save(
               %{
                 "id" => "notes",
                 "title" => "Notes",
                 "entry" => "src/App.tsx",
                 "permissions" => ["notes:write"]
               },
               workspace: workspace
             )

    assert {:ok, view} = Permissions.app("notes", workspace: workspace)
    assert view["declared_permissions"] == ["notes:write"]
    assert view["granted_permissions"] == []
    assert view["stale_granted_permissions"] == ["notes:read"]
    assert view["denied_permissions"] == ["notes:write"]

    assert {:error, "permission is not declared by app manifest"} =
             Permissions.check("notes", "notes:read", workspace: workspace)
  end

  test "list reports invalid permissions store as diagnostics", %{workspace: workspace} do
    create_notes_app!(workspace)

    path = Permissions.path(workspace: workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{bad json")

    assert %{"apps" => [], "diagnostics" => [%{"path" => ^path, "error" => error}]} =
             Permissions.list(workspace: workspace)

    assert error =~ "invalid JSON"

    assert {:error, "invalid JSON:" <> _} =
             Permissions.grant("notes", "notes:read", workspace: workspace)
  end

  test "grant and denied checks write control plane observations", %{workspace: workspace} do
    create_notes_app!(workspace)

    assert {:error, "permission is not granted"} =
             Permissions.check("notes", "notes:write", workspace: workspace)

    assert {:ok, _} = Permissions.grant("notes", "notes:write", workspace: workspace)

    observations =
      Query.query(%{"tag_prefix" => "workbench.permission.", "limit" => 10}, workspace: workspace)

    assert Enum.any?(observations, fn observation ->
             observation["tag"] == "workbench.permission.denied" and
               observation["attrs"]["app_id"] == "notes" and
               observation["attrs"]["permission"] == "notes:write" and
               observation["attrs"]["reason"] == "permission is not granted"
           end)

    assert Enum.any?(observations, fn observation ->
             observation["tag"] == "workbench.permission.granted" and
               observation["attrs"]["app_id"] == "notes" and
               observation["attrs"]["permission"] == "notes:write"
           end)
  end

  test "check rejects malformed permission values without crashing", %{workspace: workspace} do
    create_notes_app!(workspace)

    assert {:error, "permission must be a string"} =
             Permissions.check("notes", %{"bad" => "permission"}, workspace: workspace)

    assert [observation] =
             Query.query(%{"tag" => "workbench.permission.denied", "limit" => 1},
               workspace: workspace
             )

    assert observation["attrs"]["app_id"] == "notes"
    assert observation["attrs"]["permission"] =~ "%{"
    assert observation["attrs"]["reason"] == "permission must be a string"
  end

  defp create_notes_app!(workspace) do
    assert {:ok, _} =
             Store.save(
               %{
                 "id" => "notes",
                 "title" => "Notes",
                 "entry" => "src/App.tsx",
                 "permissions" => ["notes:read", "notes:write"]
               },
               workspace: workspace
             )
  end
end
