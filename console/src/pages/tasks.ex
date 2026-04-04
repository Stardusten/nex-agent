defmodule NexAgentConsole.Pages.Tasks do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(params) do
    job = Map.get(params, "job")

    panel_path =
      case job do
        job when is_binary(job) and job != "" ->
          "/api/admin/panels/tasks?job=" <> URI.encode_www_form(job)

        _ ->
          "/api/admin/panels/tasks"
      end

    %{
      title: "NexAgent Console | 调度",
      subtitle: "cron 调度与任务执行",
      current_path: "/tasks",
      panel_path: panel_path,
      primary_action_label: nil,
      primary_action_href: nil
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def run_job(req), do: cron_action(req.body["job_id"], :run)
  def enable_job(req), do: cron_action(req.body["job_id"], :enable)
  def disable_job(req), do: cron_action(req.body["job_id"], :disable)

  defp cron_action(job_id, :run) do
    if not cron_available?() do
      AdminUI.notice(%{title: "Cron 未启动", body: "调度服务未运行，请先启动网关", tone: "danger"})
    else
      case Admin.run_cron_job(job_id) do
        {:ok, _job} ->
          AdminUI.notice(%{title: "计划任务已触发", body: job_id, tone: "ok"})
          |> trigger("admin-event", %{topic: "tasks", summary: "Cron job triggered"})

        {:error, reason} ->
          AdminUI.notice(%{title: "触发失败", body: inspect(reason), tone: "danger"})
      end
    end
  end

  defp cron_action(job_id, action) do
    enabled = action == :enable

    if not cron_available?() do
      AdminUI.notice(%{title: "Cron 未启动", body: "调度服务未运行，请先启动网关", tone: "danger"})
    else
      case Admin.enable_cron_job(job_id, enabled) do
        {:ok, _job} ->
          AdminUI.notice(%{
            title: if(enabled, do: "计划任务已启用", else: "计划任务已停用"),
            body: job_id,
            tone: if(enabled, do: "ok", else: "warn")
          })
          |> trigger("admin-event", %{topic: "tasks", summary: "Cron state changed"})

        {:error, reason} ->
          AdminUI.notice(%{
            title: "更新失败",
            body: inspect(reason),
            tone: "danger"
          })
      end
    end
  end

  defp cron_available?, do: Process.whereis(Nex.Agent.Cron) != nil
end
