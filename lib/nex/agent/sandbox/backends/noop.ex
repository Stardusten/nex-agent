defmodule Nex.Agent.Sandbox.Backends.Noop do
  @moduledoc """
  Explicit no-sandbox backend.

  This backend is only selected when policy disables sandboxing, requests
  danger-full-access/external execution, or explicitly asks for `:noop`.
  """

  @behaviour Nex.Agent.Sandbox.Backend

  alias Nex.Agent.Sandbox.{Command, Policy}

  @impl true
  def name, do: :noop

  @impl true
  def available?, do: true

  @impl true
  def wrap(%Command{} = command, %Policy{}), do: {:ok, command}
end
