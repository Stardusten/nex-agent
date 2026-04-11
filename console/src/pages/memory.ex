defmodule NexAgentConsole.Pages.Memory do
  use Nex

  alias NexAgentConsole.Components.AdminUI

  def mount(_params) do
    %{
      title: "NexAgent Console | 认知",
      subtitle: "SOUL / USER / MEMORY 认知状态",
      current_path: "/memory",
      panel_path: "/api/admin/panels/memory",
      primary_action_label: "查看认知摘要",
      primary_action_href: "#memory-summary"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)
end
