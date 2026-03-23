defmodule Nex.Automation.WorkspaceManagerTest do
  use ExUnit.Case, async: false

  alias Nex.Automation.{Workflow, WorkspaceManager}
  alias Nex.Automation.Tracker.GitHub

  test "prepare creates a git worktree and an isolated agent workspace" do
    repo_root = temp_dir("workspace-manager-repo")
    worktree_root = temp_dir("workspace-manager-worktrees")
    agent_root = temp_dir("workspace-manager-agents")

    on_exit(fn ->
      File.rm_rf!(repo_root)
      File.rm_rf!(worktree_root)
      File.rm_rf!(agent_root)
    end)

    init_git_repo!(repo_root)

    workflow = %Workflow{
      repo_root: repo_root,
      workspace: %Workflow.Workspace{root: worktree_root, agent_root: agent_root}
    }

    issue = %GitHub.Issue{number: 7, title: "Fix auth flow"}

    assert {:ok, workspace} = WorkspaceManager.prepare(workflow, issue)

    assert workspace.branch == "nex/7-fix-auth-flow"
    assert File.dir?(workspace.code_path)
    assert File.dir?(workspace.agent_path)
    assert File.exists?(Path.join(workspace.agent_path, "AGENTS.md"))

    {output, 0} =
      System.cmd("git", ["-C", repo_root, "worktree", "list"], stderr_to_stdout: true)

    assert output =~ workspace.code_path
  end

  test "cleanup removes the worktree checkout and agent workspace" do
    repo_root = temp_dir("workspace-manager-cleanup-repo")
    worktree_root = temp_dir("workspace-manager-cleanup-worktrees")
    agent_root = temp_dir("workspace-manager-cleanup-agents")

    on_exit(fn ->
      File.rm_rf!(repo_root)
      File.rm_rf!(worktree_root)
      File.rm_rf!(agent_root)
    end)

    init_git_repo!(repo_root)

    workflow = %Workflow{
      repo_root: repo_root,
      workspace: %Workflow.Workspace{root: worktree_root, agent_root: agent_root}
    }

    issue = %GitHub.Issue{number: 11, title: "Tighten labels"}
    {:ok, workspace} = WorkspaceManager.prepare(workflow, issue)

    assert :ok = WorkspaceManager.cleanup(workspace)
    refute File.exists?(workspace.code_path)
    refute File.exists?(workspace.agent_path)
  end

  defp init_git_repo!(repo_root) do
    File.mkdir_p!(repo_root)
    File.write!(Path.join(repo_root, "README.md"), "# temp\n")

    {_, 0} = System.cmd("git", ["init", "-b", "main"], stderr_to_stdout: true, cd: repo_root)

    {_, 0} =
      System.cmd("git", ["config", "user.email", "test@example.com"],
        stderr_to_stdout: true,
        cd: repo_root
      )

    {_, 0} =
      System.cmd("git", ["config", "user.name", "Test User"],
        stderr_to_stdout: true,
        cd: repo_root
      )

    {_, 0} = System.cmd("git", ["add", "README.md"], stderr_to_stdout: true, cd: repo_root)
    {_, 0} = System.cmd("git", ["commit", "-m", "init"], stderr_to_stdout: true, cd: repo_root)
  end

  defp temp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end
end
