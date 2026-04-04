defmodule NexAgentConsole.Api.Admin.Panels.Tasks do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI
  alias NexAgentConsole.Support.View

  def get(req) do
    selected_job_id = req.query["job"]

    Admin.tasks_state()
    |> then(&AdminUI.tasks_panel(%{state: &1, selected_job_id: selected_job_id}))
    |> View.render()
    |> Nex.html()
  end
end
