defmodule Nex.Agent.Tool.InterruptSession do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.InboundWorker

  def name, do: "interrupt_session"
  def description, do: "Request cancellation of the current owner session through the shared control lane."
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          reason: %{
            type: "string",
            description: "Short reason to record for the interrupt request"
          }
        },
        required: ["reason"]
      }
    }
  end

  def execute(%{"reason" => reason}, ctx) when is_binary(reason) and reason != "" do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")
    session_key = Map.get(ctx, :session_key) || Map.get(ctx, "session_key")

    cond do
      not is_binary(workspace) or workspace == "" ->
        {:error, "workspace is required"}

      not is_binary(session_key) or session_key == "" ->
        {:error, "session_key is required"}

      true ->
        opts =
          []
          |> maybe_put_server(Map.get(ctx, :server) || Map.get(ctx, "server"))
          |> maybe_put_requester_pid(Map.get(ctx, :requester_pid) || Map.get(ctx, "requester_pid"))

        InboundWorker.request_interrupt(workspace, session_key, {:follow_up_tool, reason}, opts)
    end
  end

  def execute(_args, _ctx), do: {:error, "reason is required"}

  defp maybe_put_server(opts, nil), do: opts
  defp maybe_put_server(opts, server), do: Keyword.put(opts, :server, server)

  defp maybe_put_requester_pid(opts, nil), do: opts
  defp maybe_put_requester_pid(opts, requester_pid), do: Keyword.put(opts, :requester_pid, requester_pid)
end
