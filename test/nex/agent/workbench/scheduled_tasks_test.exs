defmodule Nex.Agent.Interface.Workbench.ScheduledTasksTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Capability.Cron
  alias Nex.Agent.Interface.Workbench.{Bridge, Permissions, Store}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-workbench-scheduled-tasks-#{System.unique_integer([:positive])}"
      )

    if Process.whereis(Cron) == nil do
      start_supervised!({Cron, name: Cron})
    end

    assert {:ok, _} =
             Store.save(
               %{
                 "id" => "schedule-board",
                 "title" => "Schedule Board",
                 "permissions" => ["permissions:read", "tasks:read", "tasks:write"]
               },
               workspace: workspace
             )

    on_exit(fn ->
      if Process.whereis(Cron) do
        Cron.list_jobs(workspace: workspace)
        |> Enum.each(fn job -> Cron.remove_job(job.id, workspace: workspace) end)
      end

      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "bridge manages scheduled tasks through bounded task permissions", %{workspace: workspace} do
    assert {:ok, _} = Permissions.grant("schedule-board", "tasks:read", workspace: workspace)
    assert {:ok, _} = Permissions.grant("schedule-board", "tasks:write", workspace: workspace)

    assert %{
             "ok" => true,
             "result" => %{
               "job" => %{
                 "id" => job_id,
                 "name" => "Daily planning",
                 "schedule" => %{"type" => "every", "seconds" => 3600},
                 "enabled" => true
               }
             }
           } =
             bridge_call(workspace, "add", %{
               "name" => "Daily planning",
               "message" => "Review today's active projects.",
               "schedule" => %{"type" => "every", "seconds" => 3600},
               "channel" => "feishu",
               "chat_id" => "chat-ops"
             })

    assert %{"ok" => true, "result" => %{"total" => 1, "jobs" => [listed]}} =
             bridge_call(workspace, "list", %{"query" => "planning"})

    assert listed["id"] == job_id
    assert listed["channel"] == "feishu"
    assert listed["source"] == %{"type" => "scheduled_task", "kind" => "custom"}

    assert %{
             "ok" => true,
             "result" => %{
               "job" => %{
                 "id" => ^job_id,
                 "message" => "Run the morning review.",
                 "schedule" => %{"type" => "cron", "expr" => "0 9 * * *"}
               }
             }
           } =
             bridge_call(workspace, "update", %{
               "job_id" => job_id,
               "message" => "Run the morning review.",
               "schedule" => %{"type" => "cron", "expr" => "0 9 * * *"}
             })

    assert %{"ok" => true, "result" => %{"job" => %{"enabled" => false}}} =
             bridge_call(workspace, "disable", %{"job_id" => job_id})

    assert %{"ok" => true, "result" => %{"job" => %{"enabled" => true}}} =
             bridge_call(workspace, "enable", %{"job_id" => job_id})

    assert %{"ok" => true, "result" => %{"removed" => true, "job_id" => ^job_id}} =
             bridge_call(workspace, "remove", %{"job_id" => job_id})

    assert %{"ok" => true, "result" => %{"jobs" => [], "total" => 0}} =
             bridge_call(workspace, "list", %{})
  end

  test "bridge rejects scheduled task writes without owner grant", %{workspace: workspace} do
    assert {:ok, _} = Permissions.grant("schedule-board", "tasks:read", workspace: workspace)

    assert %{"ok" => true, "result" => %{"jobs" => []}} =
             bridge_call(workspace, "list", %{})

    assert %{
             "ok" => false,
             "error" => %{"code" => "permission_denied", "message" => "permission is not granted"}
           } =
             bridge_call(workspace, "add", %{
               "name" => "Nope",
               "message" => "This should not be created.",
               "schedule" => %{"type" => "every", "seconds" => 60}
             })
  end

  test "bridge validates scheduled task params", %{workspace: workspace} do
    assert {:ok, _} = Permissions.grant("schedule-board", "tasks:write", workspace: workspace)

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "bad_params",
               "message" => "cron expression must have 5 fields"
             }
           } =
             bridge_call(workspace, "add", %{
               "name" => "Bad cron",
               "message" => "Bad expression",
               "schedule" => %{"type" => "cron", "expr" => "* * *"}
             })
  end

  defp bridge_call(workspace, action, params) do
    Bridge.call(
      "schedule-board",
      %{
        "call_id" => "call_#{action}",
        "method" => "tasks.scheduled.#{action}",
        "params" => params
      },
      workspace: workspace
    )
  end
end
