defmodule NexAgentConsole.Pages.Sessions do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI

  def mount(_params), do: {:redirect, "/evolution"}

  def render(assigns), do: AdminUI.page_shell(assigns)

  def consolidate(req) do
    session_key = req.body["session_key"]

    case Admin.consolidate_memory(session_key) do
      {:ok, payload} ->
        AdminUI.notice(%{
          title: "Consolidation 已完成",
          body: "#{payload["status"]} · #{payload["reason"]}",
          tone: "ok"
        })
        |> trigger("admin-event", %{topic: "memory", summary: "Memory consolidation finished"})

      {:error, reason} ->
        AdminUI.notice(%{
          title: "Consolidation 失败",
          body: inspect(reason),
          tone: "danger"
        })
    end
  end

  def reset(req) do
    session_key = req.body["session_key"]

    case Admin.reset_session(session_key) do
      :ok ->
        AdminUI.notice(%{
          title: "会话已清空",
          body: session_key,
          tone: "ok"
        })
        |> trigger("admin-event", %{topic: "sessions", summary: "Session reset"})

      {:error, reason} ->
        AdminUI.notice(%{
          title: "清空失败",
          body: inspect(reason),
          tone: "danger"
        })
    end
  end
end
