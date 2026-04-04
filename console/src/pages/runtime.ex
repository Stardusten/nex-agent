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

    %{
      title: "NexAgent Console | 运行时",
      subtitle: "网关状态与请求追踪",
      current_path: "/runtime",
      panel_path: panel_path,
      primary_action_label: nil,
      primary_action_href: nil
    }
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
