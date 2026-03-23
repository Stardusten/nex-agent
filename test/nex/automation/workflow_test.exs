defmodule Nex.Automation.WorkflowTest do
  use ExUnit.Case, async: true

  alias Nex.Automation.Workflow

  test "loads workflow front matter, resolves defaults, and keeps template body" do
    workflow_dir = temp_dir("workflow-load")
    workflow_path = Path.join(workflow_dir, "WORKFLOW.md")

    File.mkdir_p!(workflow_dir)

    File.write!(
      workflow_path,
      """
      ---
      tracker:
        kind: github
        owner: openai
        repo: symphony
        ready_labels:
          - agent:ready
      polling:
        interval_ms: 45000
      worker:
        command: mix nex.agent
      ---
      Analyze the issue, implement the fix, and open a PR.
      """
    )

    assert {:ok, workflow} = Workflow.load(workflow_path)

    assert workflow.path == Path.expand(workflow_path)
    assert workflow.repo_root == Path.expand(workflow_dir)
    assert workflow.prompt_template == "Analyze the issue, implement the fix, and open a PR."
    assert workflow.tracker.kind == :github
    assert workflow.tracker.owner == "openai"
    assert workflow.tracker.repo == "symphony"
    assert workflow.tracker.ready_labels == ["agent:ready"]
    assert workflow.tracker.running_label == "nex:running"
    assert workflow.tracker.review_label == "nex:review"
    assert workflow.tracker.failed_label == "nex:failed"
    assert workflow.polling.interval_ms == 45_000
    assert workflow.agent.max_concurrent_agents == 1
    assert workflow.agent.max_retry_backoff_ms == 300_000
    assert workflow.worker.command == ["mix", "nex.agent"]
    assert workflow.worker.timeout_ms == 3_600_000

    assert workflow.workspace.root ==
             Path.join(Path.expand(workflow_dir), ".nex/orchestrator/worktrees")

    assert workflow.workspace.agent_root ==
             Path.join(Path.expand(workflow_dir), ".nex/orchestrator/agents")
  end

  test "requires a github tracker owner and repo" do
    workflow_dir = temp_dir("workflow-invalid")
    workflow_path = Path.join(workflow_dir, "WORKFLOW.md")

    File.mkdir_p!(workflow_dir)

    File.write!(
      workflow_path,
      """
      ---
      tracker:
        kind: github
        owner: openai
      ---
      body
      """
    )

    assert {:error, message} = Workflow.load(workflow_path)
    assert message =~ "tracker.repo"
  end

  defp temp_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
  end
end
