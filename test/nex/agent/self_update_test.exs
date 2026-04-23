defmodule Nex.Agent.SelfUpdateTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.SelfUpdate.ReleaseStore
  alias Nex.Agent.Tool.SelfUpdate

  setup do
    repo_root =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-self-update-tool-#{System.unique_integer([:positive])}"
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

  test "tool returns structured deploy failure payload instead of flattening it to an error" do
    tmp_file =
      Path.join(System.tmp_dir!(), "self-update-outside-#{System.unique_integer([:positive])}.ex")

    File.write!(tmp_file, "defmodule OutsideSelfUpdate do\nend\n")

    on_exit(fn -> File.rm(tmp_file) end)

    assert {:ok, %{status: :failed, phase: :plan, error: error}} =
             SelfUpdate.execute(
               %{
                 "action" => "deploy",
                 "reason" => "phase10d contract",
                 "files" => [tmp_file]
               },
               %{}
             )

    assert error =~ "Only repo CODE-layer files"
  end

  test "tool status returns structured payload for explicit files", %{repo_root: repo_root} do
    code_path = Path.join(repo_root, "lib/nex/agent/sample.ex")
    test_path = Path.join(repo_root, "test/nex/agent/sample_test.exs")
    File.mkdir_p!(Path.dirname(code_path))
    File.mkdir_p!(Path.dirname(test_path))
    File.write!(code_path, "defmodule Nex.Agent.Sample do\n  def value, do: :ok\nend\n")
    File.write!(test_path, "defmodule Nex.Agent.SampleTest do\n  use ExUnit.Case\nend\n")

    assert {:ok,
            %{
              status: :ok,
              plan_source: :explicit,
              current_effective_release: nil,
              current_event_release: nil,
              previous_rollback_target: nil,
              pending_files: [pending_file],
              modules: ["Nex.Agent.Sample"],
              rollback_candidates: [],
              deployable: true,
              blocked_reasons: []
            }} =
             SelfUpdate.execute(%{"action" => "status", "files" => [code_path]}, %{})

    assert pending_file == "lib/nex/agent/sample.ex"
  end

  test "tool history returns release entries from the release store" do
    assert :ok =
             ReleaseStore.save_release(%{
               "id" => "rel-history",
               "parent_release_id" => nil,
               "timestamp" => "2026-04-24T10:00:00Z",
               "reason" => "history",
               "files" => [],
               "modules" => [],
               "tests" => [],
               "status" => "deployed"
             })

    assert {:ok,
            %{
              status: :ok,
              current_effective_release: "rel-history",
              releases: [%{id: "rel-history", effective: true}]
            }} =
             SelfUpdate.execute(%{"action" => "history"}, %{})
  end

  test "tool returns structured rollback failure payload when no release is available" do
    assert {:ok, %{status: :failed, phase: :plan, error: "No rollback target available"}} =
             SelfUpdate.execute(%{"action" => "rollback"}, %{})
  end
end
