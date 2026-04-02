defmodule NexAgentConsole.Pages.Runtime do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(params) do
    trace = Map.get(params, "trace")

    panel_path =
      case trace do
        trace when is_binary(trace) and trace != "" ->
          "/api/admin/panels/runtime?trace=" <> URI.encode_www_form(trace)

        _ ->
          "/api/admin/panels/runtime"
      end

    case trace do
      trace when is_binary(trace) and trace != "" ->
        %{
          title: "NexAgent Console | 请求 Trace",
          subtitle: "当前只看这一条请求的 trace，返回列表后再切换别的请求。",
          current_path: "/runtime",
          panel_path: panel_path,
          primary_action_label: "返回最近请求",
          primary_action_href: "/runtime"
        }

      _ ->
        %{
          title: "NexAgent Console | 运行时",
          subtitle: "运行时页只保留运行状态和最近请求索引；单条请求详情改成独立查看。",
          current_path: "/runtime",
          panel_path: panel_path,
          primary_action_label: "查看最近请求",
          primary_action_href: "#recent-request-list"
        }
    end
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def start_gateway(_req) do
    case Admin.start_gateway() do
      :ok ->
        AdminUI.notice(%{title: "网关已启动", body: "runtime is now live", tone: "ok"})
        |> trigger("admin-event", %{topic: "runtime", summary: "Gateway started"})

      {:error, reason} ->
        AdminUI.notice(%{title: "启动失败", body: inspect(reason), tone: "danger"})
    end
  end

  def stop_gateway(_req) do
    case Admin.stop_gateway() do
      :ok ->
        AdminUI.notice(%{title: "网关已停止", body: "runtime stopped", tone: "warn"})
        |> trigger("admin-event", %{topic: "runtime", summary: "Gateway stopped"})

      {:error, reason} ->
        AdminUI.notice(%{title: "停止失败", body: inspect(reason), tone: "danger"})
    end
  end
end
