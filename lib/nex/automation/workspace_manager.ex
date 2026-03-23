defmodule Nex.Automation.WorkspaceManager do
  @moduledoc false

  alias Nex.Agent.Onboarding
  alias Nex.Automation.Workflow
  alias Nex.Automation.Tracker.GitHub

  defmodule Workspace do
    @moduledoc false

    defstruct [:issue_number, :branch, :code_path, :agent_path, :repo_root]
  end

  @spec prepare(Workflow.t(), GitHub.Issue.t(), keyword()) ::
          {:ok, Workspace.t()} | {:error, String.t()}
  def prepare(%Workflow{} = workflow, %GitHub.Issue{} = issue, _opts \\ []) do
    branch = branch_name(issue)
    slug = issue_slug(issue)
    code_path = Path.join(workflow.workspace.root, "#{issue.number}-#{slug}")
    agent_path = Path.join(workflow.workspace.agent_root, Integer.to_string(issue.number))

    File.mkdir_p!(workflow.workspace.root)
    File.mkdir_p!(workflow.workspace.agent_root)

    with :ok <- ensure_worktree(workflow.repo_root, code_path, branch),
         :ok <- Onboarding.ensure_workspace_initialized(agent_path) do
      {:ok,
       %Workspace{
         issue_number: issue.number,
         branch: branch,
         code_path: Path.expand(code_path),
         agent_path: Path.expand(agent_path),
         repo_root: Path.expand(workflow.repo_root)
       }}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @spec cleanup(Workspace.t(), keyword()) :: :ok | {:error, String.t()}
  def cleanup(%Workspace{} = workspace, _opts \\ []) do
    with :ok <- remove_worktree(workspace),
         :ok <- maybe_delete_branch(workspace),
         :ok <- remove_agent_workspace(workspace.agent_path) do
      :ok
    end
  end

  defp ensure_worktree(repo_root, code_path, branch) do
    if File.dir?(code_path) do
      :ok
    else
      args = ["-C", repo_root, "worktree", "add", code_path, "-b", branch]

      case System.cmd("git", args, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _status} -> {:error, String.trim(output)}
      end
    end
  end

  defp remove_worktree(%Workspace{repo_root: repo_root, code_path: code_path}) do
    if File.exists?(code_path) do
      case System.cmd("git", ["-C", repo_root, "worktree", "remove", "--force", code_path],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, _status} -> {:error, String.trim(output)}
      end
    else
      :ok
    end
  end

  defp maybe_delete_branch(%Workspace{repo_root: repo_root, branch: branch}) do
    case System.cmd("git", ["-C", repo_root, "branch", "-D", branch], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp remove_agent_workspace(agent_path) do
    File.rm_rf!(agent_path)
    :ok
  end

  defp branch_name(issue), do: "nex/#{issue.number}-#{issue_slug(issue)}"

  defp issue_slug(%GitHub.Issue{title: title}) do
    title
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "issue"
      slug -> slug
    end
  end
end
