defmodule Nex.Agent.Self.Update.ReleaseStoreTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Self.Update.ReleaseStore

  setup do
    repo_root =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-release-store-#{System.unique_integer([:positive])}"
      )

    previous_repo_root = Application.get_env(:nex_agent, :repo_root)
    File.mkdir_p!(repo_root)
    Application.put_env(:nex_agent, :repo_root, repo_root)

    on_exit(fn ->
      if previous_repo_root do
        Application.put_env(:nex_agent, :repo_root, previous_repo_root)
      else
        Application.delete_env(:nex_agent, :repo_root)
      end

      File.rm_rf!(repo_root)
    end)

    {:ok, repo_root: repo_root}
  end

  test "ensure_layout creates release snapshot and applied directories", %{repo_root: repo_root} do
    assert :ok = ReleaseStore.ensure_layout()
    assert ReleaseStore.root_dir() == Path.join(repo_root, ".nex_self_update")
    assert File.dir?(ReleaseStore.releases_dir())
    assert File.dir?(ReleaseStore.snapshots_dir())
    assert File.dir?(ReleaseStore.applied_dir())
  end

  test "save and read snapshot and applied contents" do
    assert :ok = ReleaseStore.ensure_layout()
    assert :ok = ReleaseStore.save_snapshot("rel-1", "lib/nex/agent/sample.ex", "before")
    assert :ok = ReleaseStore.save_applied("rel-1", "lib/nex/agent/sample.ex", "after")

    assert {:ok, "before"} = ReleaseStore.read_snapshot("rel-1", "lib/nex/agent/sample.ex")
    assert {:ok, "after"} = ReleaseStore.read_applied("rel-1", "lib/nex/agent/sample.ex")
  end

  test "release visibility distinguishes current event, effective release, and rollback candidates" do
    assert :ok =
             ReleaseStore.save_release(%{
               "id" => "rel-v1",
               "parent_release_id" => nil,
               "timestamp" => "2026-04-24T09:00:00Z",
               "reason" => "v1",
               "files" => [],
               "modules" => [],
               "tests" => [],
               "status" => "deployed"
             })

    assert :ok =
             ReleaseStore.save_release(%{
               "id" => "rel-v2",
               "parent_release_id" => "rel-v1",
               "timestamp" => "2026-04-24T10:00:00Z",
               "reason" => "v2",
               "files" => [],
               "modules" => [],
               "tests" => [],
               "status" => "deployed"
             })

    assert :ok =
             ReleaseStore.save_release(%{
               "id" => "rel-rb",
               "parent_release_id" => "rel-v2",
               "timestamp" => "2026-04-24T11:00:00Z",
               "reason" => "rollback:rel-v2",
               "files" => [],
               "modules" => [],
               "tests" => [],
               "status" => "rolled_back"
             })

    assert [%{"id" => "rel-rb"}, %{"id" => "rel-v2"}, %{"id" => "rel-v1"}] =
             ReleaseStore.list_releases()

    assert %{"id" => "rel-rb"} = ReleaseStore.current_event_release()
    assert %{"id" => "rel-v2"} = ReleaseStore.current_effective_release()
    assert %{"id" => "rel-v1"} = ReleaseStore.previous_rollback_target()
    assert [%{"id" => "rel-v1"}] = ReleaseStore.rollback_candidates()

    assert %{
             status: :ok,
             current_effective_release: "rel-v2",
             releases: [
               %{id: "rel-rb", effective: false, rollback_candidate: false},
               %{id: "rel-v2", effective: true, rollback_candidate: false},
               %{id: "rel-v1", effective: false, rollback_candidate: true}
             ]
           } = ReleaseStore.history_view()

    assert {:ok, %{target_release_id: "rel-v1"}} =
             ReleaseStore.resolve_rollback_target("previous")

    assert {:ok, %{target_release_id: "rel-v1"}} = ReleaseStore.resolve_rollback_target("rel-v1")
  end

  test "release ordering uses id as a deterministic tie-breaker inside the same timestamp" do
    timestamp = "2026-04-24T10:00:00Z"

    assert :ok =
             ReleaseStore.save_release(%{
               "id" => "rel-v1",
               "parent_release_id" => nil,
               "timestamp" => timestamp,
               "reason" => "v1",
               "files" => [],
               "modules" => [],
               "tests" => [],
               "status" => "deployed"
             })

    assert :ok =
             ReleaseStore.save_release(%{
               "id" => "rel-v2",
               "parent_release_id" => "rel-v1",
               "timestamp" => timestamp,
               "reason" => "v2",
               "files" => [],
               "modules" => [],
               "tests" => [],
               "status" => "deployed"
             })

    assert [%{"id" => "rel-v2"}, %{"id" => "rel-v1"}] = ReleaseStore.list_releases()
    assert %{"id" => "rel-v2"} = ReleaseStore.current_event_release()
    assert %{"id" => "rel-v2"} = ReleaseStore.current_effective_release()
  end
end
