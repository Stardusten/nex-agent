defmodule NexAgentConsole.Pages.Evolution do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(params) do
    signal = Map.get(params, "signal")

    panel_path =
      case signal do
        signal when is_binary(signal) and signal != "" ->
          "/api/admin/panels/evolution?signal=" <> URI.encode_www_form(signal)

        _ ->
          "/api/admin/panels/evolution"
      end

    %{
      title: "NexAgent Console | 分流",
      subtitle: "信号分层判断",
      current_path: "/evolution",
      panel_path: panel_path,
      primary_action_label: nil,
      primary_action_href: nil
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def trigger_cycle(_req) do
    case Admin.run_evolution_cycle() do
      {:ok, result} ->
        AdminUI.notice(%{
          title: "Evolution cycle 已完成",
          body:
            "Soul #{result.soul_updates} / Memory #{result.memory_updates} / Skill drafts #{result.skill_candidates}",
          tone: "ok"
        })
        |> trigger("admin-event", %{
          topic: "evolution",
          summary: "Manual evolution cycle completed"
        })

      {:error, reason} ->
        AdminUI.notice(%{
          title: "Evolution cycle 失败",
          body: inspect(reason),
          tone: "danger"
        })
    end
  end
end
