defmodule Nex.Agent.Workflow.PersonalSummary do
  @moduledoc false

  alias Nex.Agent.{Capability.Executor, Knowledge}
  alias Nex.Agent.Workflow.Tasks

  @spec build(String.t(), keyword()) :: String.t()
  def build(scope, opts \\ []) when scope in ["daily", "weekly", "all"] do
    workspace = Keyword.get(opts, :workspace)
    tasks = Keyword.get(opts, :tasks, Tasks.list(workspace_opts(workspace)))
    captures = Knowledge.list(workspace_opts(workspace) ++ [limit: capture_limit(scope)])
    runs = Executor.recent_runs(workspace_opts(workspace) ++ [limit: capture_limit(scope)])

    open_tasks = Enum.count(tasks, &(&1["status"] in ["open", "snoozed"]))
    completed_tasks = Enum.count(tasks, &(&1["status"] == "completed"))

    upcoming =
      tasks
      |> Enum.filter(&(&1["status"] in ["open", "snoozed"]))
      |> Enum.filter(&(is_binary(&1["due_at"]) or is_binary(&1["follow_up_at"])))
      |> Enum.take(5)

    """
    #{header(scope)}
    Open tasks: #{open_tasks}
    Completed tasks: #{completed_tasks}
    Knowledge captures: #{length(captures)}
    Executor runs: #{length(runs)}

    Upcoming:
    #{format_upcoming(upcoming)}

    Recent knowledge:
    #{format_captures(captures)}

    Recent execution:
    #{format_runs(runs)}
    """
    |> String.trim()
  end

  defp header("daily"), do: "Daily Personal Summary"
  defp header("weekly"), do: "Weekly Personal Summary"
  defp header("all"), do: "Personal Summary"

  defp capture_limit("daily"), do: 10
  defp capture_limit("weekly"), do: 20
  defp capture_limit("all"), do: 20

  defp format_upcoming([]), do: "- none"

  defp format_upcoming(tasks) do
    Enum.map_join(tasks, "\n", fn task ->
      timestamp = task["due_at"] || task["follow_up_at"] || "unscheduled"
      "- #{task["title"]} @ #{timestamp}"
    end)
  end

  defp format_captures([]), do: "- none"

  defp format_captures(captures) do
    Enum.map_join(captures, "\n", fn capture ->
      "- [#{capture["source"]}] #{capture["title"]}"
    end)
  end

  defp format_runs([]), do: "- none"

  defp format_runs(runs) do
    Enum.map_join(runs, "\n", fn run ->
      status = run["status"] || "unknown"
      executor = run["executor"] || "executor"
      task = run["summary"] || run["task"] || "(task omitted)"
      "- #{executor} #{status}: #{String.slice(task, 0, 80)}"
    end)
  end

  defp workspace_opts(nil), do: []
  defp workspace_opts(workspace), do: [workspace: workspace]
end
