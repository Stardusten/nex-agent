defmodule Nex.Agent.Interface.Workbench.TasksTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tasks
  alias Nex.Agent.Interface.Workbench.{Bridge, Permissions, Store}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-workbench-tasks-#{System.unique_integer([:positive])}"
      )

    if Process.whereis(Tasks) == nil do
      start_supervised!({Tasks, name: Tasks})
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
      if Process.whereis(Tasks) do
        Tasks.list(workspace: workspace)
        |> Enum.each(fn task -> Tasks.delete(task.id, workspace: workspace) end)
      end

      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "bridge manages tasks through bounded task permissions", %{workspace: workspace} do
    assert {:ok, _} = Permissions.grant("schedule-board", "tasks:read", workspace: workspace)
    assert {:ok, _} = Permissions.grant("schedule-board", "tasks:write", workspace: workspace)

    assert %{
             "ok" => true,
             "result" => %{
               "task" => %{
                 "id" => task_id,
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

    assert %{"ok" => true, "result" => %{"total" => 1, "tasks" => [listed]}} =
             bridge_call(workspace, "list", %{"query" => "planning"})

    assert listed["id"] == task_id
    assert listed["channel"] == "feishu"
    assert listed["source"] == %{"type" => "task", "kind" => "custom"}

    assert %{
             "ok" => true,
             "result" => %{
               "task" => %{
                 "id" => ^task_id,
                 "message" => "Run the morning review.",
                 "schedule" => %{"type" => "cron", "expr" => "0 9 * * *"}
               }
             }
           } =
             bridge_call(workspace, "update", %{
               "task_id" => task_id,
               "message" => "Run the morning review.",
               "schedule" => %{"type" => "cron", "expr" => "0 9 * * *"}
             })

    assert %{"ok" => true, "result" => %{"task" => %{"enabled" => false}}} =
             bridge_call(workspace, "disable", %{"task_id" => task_id})

    assert %{"ok" => true, "result" => %{"task" => %{"enabled" => true}}} =
             bridge_call(workspace, "enable", %{"task_id" => task_id})

    assert %{"ok" => true, "result" => %{"removed" => true, "task_id" => ^task_id}} =
             bridge_call(workspace, "remove", %{"task_id" => task_id})

    assert %{"ok" => true, "result" => %{"tasks" => [], "total" => 0}} =
             bridge_call(workspace, "list", %{})
  end

  test "bridge rejects task writes without owner grant", %{workspace: workspace} do
    assert {:ok, _} = Permissions.grant("schedule-board", "tasks:read", workspace: workspace)

    assert %{"ok" => true, "result" => %{"tasks" => []}} =
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

  test "bridge validates task params", %{workspace: workspace} do
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
        "method" => "tasks.#{method_name(action)}",
        "params" => params
      },
      workspace: workspace
    )
  end

  defp method_name("add"), do: "upsert"
  defp method_name("update"), do: "upsert"
  defp method_name("remove"), do: "delete"
  defp method_name(action), do: action
end
