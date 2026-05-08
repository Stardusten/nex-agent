defmodule Nex.Agent.SelfUpdateCommitTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Capability.Tool.Core.SelfUpdateCommit
  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Sandbox.Approval
  alias Nex.Agent.Self.Update.{Committer, ReleaseStore}
  require Log

  setup do
    repo_root =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-source-commit-#{System.unique_integer([:positive])}"
      )

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-source-commit-ws-#{System.unique_integer([:positive])}"
      )

    previous_repo_root = Application.get_env(:nex_agent, :repo_root)
    previous_workspace = Application.get_env(:nex_agent, :workspace_path)

    File.mkdir_p!(repo_root)
    File.mkdir_p!(workspace)
    Application.put_env(:nex_agent, :repo_root, repo_root)
    Application.put_env(:nex_agent, :workspace_path, workspace)

    git!(repo_root, ["init"])
    git!(repo_root, ["config", "user.email", "self-update@example.com"])
    git!(repo_root, ["config", "user.name", "Self Update Test"])

    File.write!(Path.join(repo_root, ".gitignore"), "/.nex_self_update/\n")
    source_path = Path.join(repo_root, "lib/nex/agent/sample.ex")
    File.mkdir_p!(Path.dirname(source_path))
    File.write!(source_path, sample_source(:v1))
    git!(repo_root, ["add", "."])
    git!(repo_root, ["commit", "-m", "init"])

    before_sha = sha256(File.read!(source_path))
    File.write!(source_path, sample_source(:v2))
    after_sha = sha256(File.read!(source_path))

    release_id = "rel-source-commit"

    :ok =
      ReleaseStore.save_release(%{
        "id" => release_id,
        "parent_release_id" => nil,
        "timestamp" => "2026-05-06T00:00:00Z",
        "reason" => "owner-approved retry fix",
        "candidate_id" => "cand-source-commit",
        "evidence_ids" => [],
        "files" => [
          %{
            "path" => "lib/nex/agent/sample.ex",
            "before_sha" => before_sha,
            "after_sha" => after_sha
          }
        ],
        "modules" => ["Nex.Agent.Sample"],
        "tests" => [%{"path" => "test/nex/agent/sample_test.exs", "status" => "passed"}],
        "status" => "deployed"
      })

    on_exit(fn ->
      if previous_repo_root do
        Application.put_env(:nex_agent, :repo_root, previous_repo_root)
      else
        Application.delete_env(:nex_agent, :repo_root)
      end

      if previous_workspace do
        Application.put_env(:nex_agent, :workspace_path, previous_workspace)
      else
        Application.delete_env(:nex_agent, :workspace_path)
      end

      File.rm_rf!(repo_root)
      File.rm_rf!(workspace)
    end)

    config =
      Config.from_map(%{
        "self_update" => %{
          "source_repo" => %{"path" => repo_root, "check_consistency" => true}
        }
      })

    {:ok,
     repo_root: repo_root,
     workspace: workspace,
     config: config,
     release_id: release_id,
     source_path: source_path}
  end

  test "prepare builds a commit message from release, candidate, and evidence", %{
    workspace: workspace,
    config: config,
    release_id: release_id
  } do
    {:ok, evidence} =
      Log.error(
        "runner.tool.call.failed",
        %{"error_summary" => "retry path crashed"},
        workspace: workspace
      )

    {:ok, _candidate} =
      Log.info(
        "evolution.candidate.proposed",
        %{
          "id" => "cand-source-commit",
          "kind" => "code_hint",
          "summary" => "Tighten retry handling",
          "rationale" => "Repeated retry failures",
          "evidence_ids" => [evidence["id"]],
          "risk" => "medium",
          "requires_owner_approval" => true
        },
        workspace: workspace
      )

    assert {:ok, proposal} =
             Committer.prepare(
               %{"release_id" => release_id, "candidate_id" => "cand-source-commit"},
               %{workspace: workspace, config: config}
             )

    assert proposal.subject == "self_update: Tighten retry handling"
    assert proposal.message =~ "self_update release: #{release_id}"
    assert proposal.message =~ "candidate: cand-source-commit"
    assert proposal.message =~ "runner.tool.call.failed"
    assert proposal.message =~ "retry path crashed"
    assert proposal.changed_files == ["lib/nex/agent/sample.ex"]
  end

  test "commit waits for owner approval before creating git commit", %{
    repo_root: repo_root,
    workspace: workspace,
    config: config,
    release_id: release_id
  } do
    {:ok, _candidate} = candidate_observation(workspace)

    approval_server = Module.concat(__MODULE__, :"Approval#{System.unique_integer([:positive])}")
    start_supervised!({Approval, name: approval_server})

    ctx = %{
      workspace: workspace,
      config: config,
      session_key: "feishu:self-update-commit",
      channel: "feishu",
      chat_id: "self-update-commit",
      approval_server: approval_server
    }

    task =
      Task.async(fn ->
        SelfUpdateCommit.execute(
          %{
            "action" => "commit",
            "release_id" => release_id,
            "candidate_id" => "cand-source-commit"
          },
          ctx
        )
      end)

    assert eventually(fn ->
             Approval.pending?(workspace, "feishu:self-update-commit", server: approval_server)
           end)

    [request] = Approval.pending(workspace, "feishu:self-update-commit", server: approval_server)
    assert request.description =~ "Create source repo commit"
    assert request.metadata["release_id"] == release_id
    assert request.metadata["commit_message"] =~ "self_update release: #{release_id}"

    assert {:ok, %{approved: 1, choice: :once}} =
             Approval.approve(workspace, "feishu:self-update-commit", :once,
               server: approval_server
             )

    assert {:ok, %{status: :committed, commit_sha: commit_sha}} = Task.await(task, 5_000)
    assert String.length(commit_sha) == 40

    message = git!(repo_root, ["log", "-1", "--pretty=%B"])
    assert message =~ "self_update release: #{release_id}"
    assert message =~ "owner-approved retry fix"

    assert git!(repo_root, ["status", "--porcelain"]) == ""
  end

  test "status reports missing source repo config without reading default config" do
    assert {:ok, %{configured: false, warnings: [warning]}} =
             SelfUpdateCommit.execute(%{"action" => "status"}, %{})

    assert warning =~ "self_update.source_repo.path is not configured"
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp sample_source(:v1), do: "defmodule Nex.Agent.Sample do\n  def value, do: :v1\nend\n"
  defp sample_source(:v2), do: "defmodule Nex.Agent.Sample do\n  def value, do: :v2\nend\n"

  defp candidate_observation(workspace) do
    Log.info(
      "evolution.candidate.proposed",
      %{
        "id" => "cand-source-commit",
        "kind" => "code_hint",
        "summary" => "Tighten retry handling",
        "rationale" => "Repeated retry failures",
        "evidence_ids" => [],
        "risk" => "medium",
        "requires_owner_approval" => true
      },
      workspace: workspace
    )
  end

  defp git!(repo_root, args) do
    case System.cmd("git", args, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
