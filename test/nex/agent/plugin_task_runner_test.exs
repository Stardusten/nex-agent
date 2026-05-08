defmodule Nex.Agent.PluginTaskRunnerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Observe.ControlPlane.Query
  alias Nex.Agent.Tasks.Runner

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-plugin-task-runner-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Runner) == nil do
      start_supervised!({Runner, name: Runner})
    end

    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  test "debounce executes only the latest rendered context", %{workspace: workspace} do
    task =
      plugin_task(%{
        "id" => "echo.flush",
        "policy" => %{
          "debounce_key" => "{{plugin.id}}:retain:{{session.key}}",
          "debounce_ms" => 40,
          "max_runs" => 1
        },
        "action" => %{
          "type" => "write_workspace_file",
          "path" => "plugin_data/echo/state.txt",
          "content" => "{{turn.prompt}}"
        }
      })

    Runner.enqueue_task(
      "workspace:demo",
      "echo.flush",
      "conversation.turn.finished",
      ctx(workspace, task, "old")
    )

    Runner.enqueue_task(
      "workspace:demo",
      "echo.flush",
      "conversation.turn.finished",
      ctx(workspace, task, "new")
    )

    assert eventually(fn ->
             File.read(Path.join(workspace, "plugin_data/echo/state.txt")) == {:ok, "new"}
           end)

    refute File.read!(Path.join(workspace, "plugin_data/echo/state.txt")) == "old"

    assert eventually(fn ->
             count_observations(workspace, "plugin.task.started") == 1 and
               count_observations(workspace, "plugin.task.finished") == 1 and
               observation_reason?(workspace, "plugin.task.debounced", "debounce_replaced")
           end)
  end

  test "max_runs one suppresses duplicate runs in the same trigger batch", %{workspace: workspace} do
    task =
      plugin_task(%{
        "id" => "echo.once",
        "policy" => %{"max_runs" => 1},
        "action" => %{
          "type" => "write_workspace_file",
          "path" => "plugin_data/echo/once.txt",
          "content" => "{{turn.prompt}}"
        }
      })

    Runner.enqueue_task(
      "workspace:demo",
      "echo.once",
      "conversation.turn.finished",
      ctx(workspace, task, "first")
    )

    Runner.enqueue_task(
      "workspace:demo",
      "echo.once",
      "conversation.turn.finished",
      ctx(workspace, task, "second")
    )

    assert eventually(fn -> File.exists?(Path.join(workspace, "plugin_data/echo/once.txt")) end)

    assert eventually(fn ->
             count_observations(workspace, "plugin.task.started") == 1 and
               count_observations(workspace, "plugin.task.finished") == 1 and
               observation_reason?(workspace, "plugin.task.debounced", "max_runs_reached")
           end)
  end

  test "unsupported plugin task actions fail closed", %{workspace: workspace} do
    task =
      plugin_task(%{
        "id" => "echo.shell",
        "action" => %{"type" => "shell", "command" => "echo forbidden"}
      })

    Runner.enqueue_task(
      "workspace:demo",
      "echo.shell",
      "conversation.turn.finished",
      ctx(workspace, task, "ignored")
    )

    assert eventually(fn ->
             Query.query(%{"tag" => "plugin.task.failed", "limit" => 10}, workspace: workspace)
             |> Enum.any?(fn obs ->
               get_in(obs, ["attrs", "error_summary"]) =~ "Unsupported plugin task action: shell"
             end)
           end)
  end

  test "malformed tool_call actions fail closed", %{workspace: workspace} do
    task =
      plugin_task(%{
        "id" => "echo.malformed_tool_call",
        "action" => %{"type" => "tool_call", "args" => %{}}
      })

    Runner.enqueue_task(
      "workspace:demo",
      "echo.malformed_tool_call",
      "conversation.turn.finished",
      ctx(workspace, task, "ignored")
    )

    assert eventually(fn ->
             Query.query(%{"tag" => "plugin.task.failed", "limit" => 10}, workspace: workspace)
             |> Enum.any?(fn obs ->
               get_in(obs, ["attrs", "error_summary"]) =~
                 "Plugin task tool_call requires action.tool"
             end)
           end)
  end

  defp plugin_task(attrs) do
    %{
      "kind" => "task",
      "plugin_id" => "workspace:demo",
      "plugin_root" => nil,
      "id" => attrs["id"],
      "source" => "workspace",
      "attrs" => attrs
    }
  end

  defp ctx(workspace, task, prompt) do
    %{
      workspace: workspace,
      session_key: "discord:task-runner",
      turn_prompt: prompt,
      plugin_data: %{contributions: %{tasks: [task]}}
    }
  end

  defp count_observations(workspace, tag) do
    Query.query(%{"tag" => tag, "limit" => 20}, workspace: workspace)
    |> length()
  end

  defp observation_reason?(workspace, tag, reason) do
    Query.query(%{"tag" => tag, "limit" => 20}, workspace: workspace)
    |> Enum.any?(&(get_in(&1, ["attrs", "reason"]) == reason))
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
end
