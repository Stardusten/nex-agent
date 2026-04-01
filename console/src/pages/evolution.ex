defmodule NexAgentConsole.Pages.Evolution do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | 分流",
      subtitle: "分流页先判断变化该落到哪一层，不直接展开认知原文、能力库存或代码编辑。",
      current_path: "/evolution",
      panel_path: "/api/admin/panels/evolution",
      primary_action_label: "查看待分流 signals",
      primary_action_href: "#pending-signals"
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
