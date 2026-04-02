defmodule NexAgentConsole.Api.Admin.Panels.Runtime do
  use Nex

  alias Nex.Agent.Admin
  alias NexAgentConsole.Components.AdminUI
  alias NexAgentConsole.Support.View

  def get(req) do
    trace = req.query["trace"]

    Admin.runtime_state(trace: trace)
    |> then(&AdminUI.runtime_panel(%{state: &1, trace_mode: trace_mode(trace)}))
    |> View.render()
    |> Nex.html()
  end

  defp trace_mode(trace) when is_binary(trace) and trace != "", do: :detail
  defp trace_mode(_trace), do: :index
end
