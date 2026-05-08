defmodule Nex.Agent.TasksWorkspaceTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Runtime.Workspace, Tasks}

  setup do
    workspace_a =
      Path.join(System.tmp_dir!(), "nex-agent-tasks-a-#{System.unique_integer([:positive])}")

    workspace_b =
      Path.join(System.tmp_dir!(), "nex-agent-tasks-b-#{System.unique_integer([:positive])}")

    Workspace.ensure!(workspace: workspace_a)
    Workspace.ensure!(workspace: workspace_b)

    if Process.whereis(Tasks) == nil do
      start_supervised!({Tasks, name: Tasks})
    end

    on_exit(fn ->
      Enum.each([workspace_a, workspace_b], fn workspace ->
        if Process.whereis(Tasks) do
          Tasks.list(workspace: workspace)
          |> Enum.each(fn task -> Tasks.delete(task.id, workspace: workspace) end)
        end

        File.rm_rf(workspace)
      end)
    end)

    {:ok, workspace_a: workspace_a, workspace_b: workspace_b}
  end

  test "tasks stay isolated per workspace", %{
    workspace_a: workspace_a,
    workspace_b: workspace_b
  } do
    {:ok, job_a} =
      Tasks.upsert(
        %{
          name: "workspace-a-job",
          message: "run in workspace a",
          channel: "feishu",
          chat_id: "chat-a",
          schedule: %{type: :at, timestamp: System.system_time(:second) + 3600},
          delete_after_run: true
        },
        workspace: workspace_a
      )

    {:ok, job_b} =
      Tasks.upsert(
        %{
          name: "workspace-b-job",
          message: "run in workspace b",
          channel: "feishu",
          chat_id: "chat-b",
          schedule: %{type: :at, timestamp: System.system_time(:second) + 3600},
          delete_after_run: true
        },
        workspace: workspace_b
      )

    assert Enum.map(Tasks.list(workspace: workspace_a), & &1.id) == [job_a.id]
    assert Enum.map(Tasks.list(workspace: workspace_b), & &1.id) == [job_b.id]

    assert {:ok, disabled} = Tasks.enable(job_a.id, false, workspace: workspace_a)
    assert disabled.enabled == false
    refute Enum.any?(Tasks.list(workspace: workspace_a), &(&1.id == job_a.id and &1.enabled))
    assert Enum.any?(Tasks.list(workspace: workspace_b), &(&1.id == job_b.id))
  end
end
