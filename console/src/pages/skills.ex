defmodule NexAgentConsole.Pages.Skills do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | 能力",
      subtitle: "SKILL / TOOL 资产与命中记录",
      current_path: "/skills",
      panel_path: "/api/admin/panels/skills",
      primary_action_label: "查看最近命中",
      primary_action_href: "#recent-hits"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def publish_draft(req) do
    case Admin.publish_draft_skill(req.body["name"]) do
      {:ok, skill} ->
        AdminUI.notice(%{
          title: "草稿已发布",
          body: "#{Map.get(skill, :name) || Map.get(skill, "name")} 已进入能力库存",
          tone: "ok"
        })
        |> trigger("admin-event", %{topic: "skills", summary: "Draft skill published"})

      {:error, reason} ->
        AdminUI.notice(%{title: "发布失败", body: reason, tone: "danger"})
    end
  end
end
