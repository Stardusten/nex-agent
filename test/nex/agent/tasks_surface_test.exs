defmodule Nex.Agent.TasksSurfaceTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Runtime, Runtime.Config, Tasks}
  alias Nex.Agent.Capability.Tool.Registry
  alias Nex.Agent.Tasks.Store

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-tasks-surface-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "tasks"))

    if Process.whereis(Tasks) == nil do
      start_supervised!({Tasks, name: Tasks})
    end

    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  test "public task api owns scheduled task lifecycle", %{workspace: workspace} do
    assert {:ok, task} =
             Tasks.upsert(
               %{
                 name: "Morning review",
                 message: "Review active projects.",
                 schedule: %{type: :every, seconds: 3600},
                 channel: "feishu",
                 chat_id: "chat-ops"
               },
               workspace: workspace
             )

    assert {:ok, ^task} = Tasks.get(task.id, workspace: workspace)
    assert [%Tasks{id: task_id}] = Tasks.list(workspace: workspace)
    assert task_id == task.id

    assert {:ok, disabled} = Tasks.enable(task.id, false, workspace: workspace)
    assert disabled.enabled == false

    assert {:error, :not_found} = Tasks.run_now("missing-task", %{}, workspace: workspace)

    assert :ok = Tasks.delete(task.id, workspace: workspace)
    assert [] = Tasks.list(workspace: workspace)
  end

  test "public task api accepts string keyed attrs for updates", %{workspace: workspace} do
    assert {:ok, task} =
             Tasks.upsert(
               %{
                 "id" => "string-keyed-task",
                 "name" => "Initial",
                 "message" => "Initial message.",
                 "schedule" => %{"type" => "every", "seconds" => 3600},
                 "enabled" => true
               },
               workspace: workspace
             )

    assert task.id == "string-keyed-task"
    assert task.schedule == %{type: :every, seconds: 3600}

    assert {:ok, updated} =
             Tasks.upsert(
               %{
                 "id" => "string-keyed-task",
                 "message" => "Updated through string keys.",
                 "channel" => "feishu",
                 "chat_id" => "chat-ops",
                 "enabled" => false
               },
               workspace: workspace
             )

    assert updated.name == "Initial"
    assert updated.message == "Updated through string keys."
    assert updated.channel == "feishu"
    assert updated.chat_id == "chat-ops"
    assert updated.enabled == false
  end

  test "runtime snapshot projects workspace and plugin tasks", %{workspace: workspace} do
    File.write!(
      Store.path(workspace: workspace),
      Jason.encode!([
        %{
          "id" => "workspace.summary",
          "title" => "Workspace summary",
          "enabled" => true,
          "triggers" => [
            %{"type" => "schedule", "schedule" => %{"type" => "cron", "expr" => "0 9 * * *"}}
          ],
          "action" => %{"type" => "agent_turn", "message" => "Summarize workspace"}
        }
      ])
    )

    plugin_data = %{
      contributions: %{
        tasks: [
          %{
            "id" => "plugin.retain",
            "plugin_id" => "workspace:memory",
            "attrs" => %{
              "id" => "plugin.retain",
              "action" => %{"type" => "tool_call", "tool" => "memory__retain", "args" => %{}}
            }
          }
        ]
      }
    }

    config = Config.default_map() |> Config.from_map()

    assert {:ok, pid} =
             Runtime.start_link(
               name: :"runtime_tasks_surface_#{System.unique_integer([:positive])}",
               config_loader: fn _ -> config end,
               plugins_builder: fn _ -> plugin_data end,
               tool_definitions_builder: fn _surface, _opts -> [] end,
               workspace: workspace
             )

    assert {:ok, snapshot} = GenServer.call(pid, :current)
    ids = Enum.map(snapshot.tasks.definitions, & &1["id"])
    assert "workspace.summary" in ids
    assert "plugin.retain" in ids
    assert snapshot.tasks.path == Store.path(workspace: workspace)
  end

  test "legacy cron_jobs file migrates once to tasks.json", %{workspace: workspace} do
    legacy_path = Path.join([workspace, "tasks", "cron_jobs.json"])
    tasks_path = Store.path(workspace: workspace)

    File.write!(
      legacy_path,
      Jason.encode!([%{"id" => "legacy.daily", "name" => "Legacy daily", "enabled" => true}])
    )

    assert [%{"id" => "legacy.daily"}] = Store.read_raw(workspace: workspace)
    assert File.exists?(tasks_path)
    refute File.exists?(legacy_path)
  end

  test "old public modules are not available" do
    assert {:error, :nofile} = Code.ensure_loaded(Nex.Agent.Capability.Cron)
    assert {:error, :nofile} = Code.ensure_loaded(Nex.Agent.Interface.Workbench.ScheduledTasks)
    assert {:error, :nofile} = Code.ensure_loaded(Nex.Agent.Runtime.PluginJobRunner)
    assert {:error, :nofile} = Code.ensure_loaded(Nex.Agent.Tool.Cron)

    refute "cron" in (Registry.definitions(:all) |> Enum.map(& &1["name"]))
    refute "cron" in (Registry.definitions(:base) |> Enum.map(& &1["name"]))
  end
end
