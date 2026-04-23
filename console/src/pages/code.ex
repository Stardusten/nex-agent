defmodule NexAgentConsole.Pages.Code do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(params) do
    panel_path =
      case Map.get(params, "module") do
        module when is_binary(module) and module != "" ->
          "/api/admin/panels/code?module=" <> URI.encode_www_form(module)

        _ ->
          "/api/admin/panels/code"
      end

    %{
      title: "NexAgent Console | 代码",
      subtitle: "只读源码审查与 release 观察",
      current_path: "/code",
      panel_path: panel_path,
      primary_action_label: "查看当前源码",
      primary_action_href: "#source-preview"
    }
  end

  def render(assigns), do: AdminUI.page_shell(assigns)

  def preview(req) do
    _ = req

    AdminUI.notice(%{
      title: "已移除源码粘贴预览",
      body: "Console 不再接受整块源码预览。请在 agent 主链里使用 find / read / apply_patch，并用 self_update deploy 激活代码变更。",
      tone: "warn"
    })
  end

  def hot_upgrade(req) do
    _ = req

    AdminUI.notice(%{
      title: "已移除整块源码 deploy",
      body: "Console 侧不再提供整块源码覆盖部署。请通过 agent 的 apply_patch 工作流修改文件，再使用 self_update deploy 进行激活。",
      tone: "danger"
    })
  end

  def rollback(req) do
    case Admin.rollback_code_update(req.body["module"], req.body["version_id"]) do
      {:ok, result} ->
        release_id = Map.get(result, :release_id, "ok")

        AdminUI.notice(%{
          title: "回滚已应用",
          body: "#{req.body["module"]} · release #{release_id}",
          tone: "warn"
        })
        |> trigger("admin-event", %{topic: "code", summary: "Rollback applied"})

      {:error, reason} ->
        AdminUI.notice(%{title: "回滚失败", body: reason, tone: "danger"})
    end
  end
end
