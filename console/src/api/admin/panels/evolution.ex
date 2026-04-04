defmodule NexAgentConsole.Api.Admin.Panels.Evolution do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI
  alias NexAgentConsole.Support.View

  def get(req) do
    selected_signal_id = req.query["signal"]

    Admin.evolution_state()
    |> then(&AdminUI.evolution_panel(%{state: &1, selected_signal_id: selected_signal_id}))
    |> View.render()
    |> Nex.html()
  end
end
