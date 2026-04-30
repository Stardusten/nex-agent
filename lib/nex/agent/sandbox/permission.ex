defmodule Nex.Agent.Sandbox.Permission do
  @moduledoc """
  Thin permission decision facade for sandbox callers.

  Later stages will route path and command decisions through this module so
  tools do not talk to approval state directly.
  """

  alias Nex.Agent.Sandbox.Approval
  alias Nex.Agent.Sandbox.Approval.Request

  @spec approved?(Request.t(), keyword()) :: boolean()
  def approved?(%Request{} = request, opts \\ []) do
    Approval.approved?(request.workspace, request.session_key, request, opts)
  end

  @spec request(Request.t() | map() | keyword(), keyword()) :: Approval.approval_result()
  def request(request, opts \\ []), do: Approval.request(request, opts)
end
