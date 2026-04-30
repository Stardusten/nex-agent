defmodule Nex.Agent.Sandbox.Backend do
  @moduledoc """
  Behaviour for platform-specific sandbox process wrappers.

  Backends only transform a normalized command into the command that should be
  spawned. `Nex.Agent.Sandbox.Exec` owns env filtering, timeout, cancellation,
  output handling, and observations.
  """

  alias Nex.Agent.Sandbox.{Command, Policy}

  @callback name() :: atom()
  @callback available?() :: boolean()
  @callback wrap(Command.t(), Policy.t()) :: {:ok, Command.t()} | {:error, term()}
end
