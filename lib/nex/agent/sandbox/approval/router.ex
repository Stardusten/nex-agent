defmodule Nex.Agent.Sandbox.Approval.Router do
  @moduledoc """
  Routes approval requests to the correct owner surface.

  Session-originated tool approvals stay in the originating session. Runtime
  lifecycle approvals, such as plugin environment injection, go to Workbench so
  they do not block or spam chat sessions without a direct user action source.
  """

  alias Nex.Agent.Sandbox.Approval.Request

  @type route :: :session | :workbench

  @spec route(Request.t()) :: route()
  def route(%Request{metadata: metadata} = request) do
    cond do
      explicit_workbench?(metadata) -> :workbench
      request.kind == :runtime_env -> :workbench
      request.kind == :runtime_service -> :workbench
      present?(request.channel) and present?(request.chat_id) -> :session
      true -> :workbench
    end
  end

  defp explicit_workbench?(metadata) when is_map(metadata) do
    Map.get(metadata, "delivery") in ["workbench", :workbench] or
      Map.get(metadata, :delivery) in ["workbench", :workbench]
  end

  defp explicit_workbench?(_metadata), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
