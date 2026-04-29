defmodule Nex.Agent.Interface.Workbench.NotesTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Observe.ControlPlane.Query
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Interface.Workbench.{Bridge, Permissions, Store}

  setup do
    previous_allowed_roots = System.get_env("NEX_ALLOWED_ROOTS")
    System.delete_env("NEX_ALLOWED_ROOTS")

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-workbench-notes-#{System.unique_integer([:positive])}"
      )

    root = Path.join(workspace, "vault")
    File.mkdir_p!(root)

    on_exit(fn ->
      if previous_allowed_roots,
        do: System.put_env("NEX_ALLOWED_ROOTS", previous_allowed_roots),
        else: System.delete_env("NEX_ALLOWED_ROOTS")

      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace, root: root}
  end

  test "lists reads writes and searches Markdown notes through the bridge", %{
    workspace: workspace,
    root: root
  } do
    File.mkdir_p!(Path.join(root, "projects"))
    File.write!(Path.join(root, "Index.md"), "# Index\n\nHello [[World]].\n")
    File.write!(Path.join([root, "projects", "Plan.md"]), "# Plan\n\nShip notes MVP.\n")
    File.write!(Path.join(root, "ignore.txt"), "not a note")

    snapshot = snapshot(workspace, root)
    create_app!(workspace, ["permissions:read", "notes:read", "notes:write"])
    grant!(workspace, "permissions:read")
    grant!(workspace, "notes:read")
    grant!(workspace, "notes:write")

    assert %{
             "ok" => true,
             "result" => %{"roots" => [%{"id" => "notes", "configured" => true}]}
           } = call(snapshot, "notes.roots.list", %{})

    assert %{"ok" => true, "result" => %{"files" => files}} =
             call(snapshot, "notes.files.list", %{"root_id" => "notes"})

    assert Enum.map(files, & &1["path"]) == ["Index.md", "projects/Plan.md"]

    assert %{
             "ok" => true,
             "result" => %{
               "content" => content,
               "revision" => revision,
               "path" => "Index.md"
             }
           } = call(snapshot, "notes.file.read", %{"root_id" => "notes", "path" => "Index.md"})

    assert content =~ "Hello"

    assert %{"ok" => true, "result" => %{"revision" => new_revision}} =
             call(snapshot, "notes.file.write", %{
               "root_id" => "notes",
               "path" => "Index.md",
               "content" => content <> "\nSaved from Workbench.\n",
               "base_revision" => revision
             })

    assert new_revision != revision
    assert File.read!(Path.join(root, "Index.md")) =~ "Saved from Workbench"

    assert %{"ok" => true, "result" => %{"results" => [%{"path" => "projects/Plan.md"}]}} =
             call(snapshot, "notes.search", %{"root_id" => "notes", "query" => "MVP"})

    assert %{"ok" => true, "result" => %{"deleted" => true, "path" => "projects/Plan.md"}} =
             call(snapshot, "notes.file.delete", %{
               "root_id" => "notes",
               "path" => "projects/Plan.md"
             })

    refute File.exists?(Path.join([root, "projects", "Plan.md"]))
    refute File.exists?(Path.join(root, "projects"))

    observations =
      Query.query(%{"tag_prefix" => "workbench.notes.", "limit" => 20}, workspace: workspace)

    assert Enum.any?(observations, &(&1["tag"] == "workbench.notes.roots.listed"))
    assert Enum.any?(observations, &(&1["tag"] == "workbench.notes.files.listed"))
    assert Enum.any?(observations, &(&1["tag"] == "workbench.notes.file.read"))
    assert Enum.any?(observations, &(&1["tag"] == "workbench.notes.file.written"))
    assert Enum.any?(observations, &(&1["tag"] == "workbench.notes.file.deleted"))
    assert Enum.any?(observations, &(&1["tag"] == "workbench.notes.search.completed"))
  end

  test "enforces notes permissions and path boundaries", %{workspace: workspace, root: root} do
    File.write!(Path.join(root, "Index.md"), "# Index\n")

    snapshot = snapshot(workspace, root)
    create_app!(workspace, ["permissions:read"])

    assert %{"ok" => false, "error" => %{"code" => "permission_denied"}} =
             call(snapshot, "notes.files.list", %{"root_id" => "notes"})

    create_app!(workspace, ["permissions:read", "notes:read", "notes:write"])
    grant!(workspace, "notes:read")
    grant!(workspace, "notes:write")

    assert %{"ok" => false, "error" => %{"code" => "path_forbidden"}} =
             call(snapshot, "notes.file.read", %{"root_id" => "notes", "path" => "../secret.md"})

    assert %{"ok" => false, "error" => %{"code" => "path_forbidden"}} =
             call(snapshot, "notes.file.write", %{
               "root_id" => "notes",
               "path" => "not-markdown.txt",
               "content" => "nope"
             })
  end

  test "write detects external modifications", %{workspace: workspace, root: root} do
    path = Path.join(root, "Index.md")
    File.write!(path, "# Index\n")

    snapshot = snapshot(workspace, root)
    create_app!(workspace, ["notes:read", "notes:write"])
    grant!(workspace, "notes:read")
    grant!(workspace, "notes:write")

    assert %{"ok" => true, "result" => %{"revision" => revision}} =
             call(snapshot, "notes.file.read", %{"root_id" => "notes", "path" => "Index.md"})

    File.write!(path, "# Changed elsewhere\n")

    assert %{
             "ok" => false,
             "error" => %{"code" => "conflict", "message" => "note changed" <> _}
           } =
             call(snapshot, "notes.file.write", %{
               "root_id" => "notes",
               "path" => "Index.md",
               "content" => "# Mine\n",
               "base_revision" => revision
             })

    assert %{
             "ok" => false,
             "error" => %{"code" => "conflict", "message" => "note changed" <> _}
           } =
             call(snapshot, "notes.file.delete", %{
               "root_id" => "notes",
               "path" => "Index.md",
               "base_revision" => revision
             })

    assert File.exists?(path)
  end

  test "missing configured root reports no roots and rejects file calls", %{workspace: workspace} do
    snapshot = %Snapshot{
      workspace: workspace,
      config: Config.from_map(%{"gateway" => %{"workbench" => %{"enabled" => true}}})
    }

    create_app!(workspace, ["notes:read"])
    grant!(workspace, "notes:read")

    assert %{"ok" => true, "result" => %{"roots" => []}} =
             call(snapshot, "notes.roots.list", %{})

    assert %{"ok" => false, "error" => %{"code" => "root_missing"}} =
             call(snapshot, "notes.files.list", %{"root_id" => "notes"})
  end

  defp snapshot(workspace, root) do
    %Snapshot{
      workspace: workspace,
      config:
        Config.from_map(%{
          "gateway" => %{
            "workbench" => %{
              "enabled" => true,
              "apps" => %{"notes" => %{"root" => root}}
            }
          }
        })
    }
  end

  defp create_app!(workspace, permissions) do
    assert {:ok, _} =
             Store.save(
               %{
                 "id" => "notes",
                 "title" => "Notes",
                 "permissions" => permissions
               },
               workspace: workspace
             )
  end

  defp grant!(workspace, permission) do
    assert {:ok, _} = Permissions.grant("notes", permission, workspace: workspace)
  end

  defp call(snapshot, method, params) do
    Bridge.call(
      "notes",
      %{
        "call_id" => "call_#{System.unique_integer([:positive])}",
        "method" => method,
        "params" => params
      },
      snapshot
    )
  end
end
