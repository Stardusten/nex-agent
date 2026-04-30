defmodule Nex.Agent.Sandbox.Process do
  @moduledoc """
  Long-running sandboxed child process handle.
  """

  alias Nex.Agent.Sandbox.{Command, Policy}

  @type event :: {:data, binary()} | :eof | {:exit_status, non_neg_integer()}

  @type t :: %__MODULE__{
          id: String.t(),
          port: port(),
          command: Command.t(),
          policy: Policy.t(),
          sandbox: map()
        }

  @enforce_keys [:id, :port, :command, :policy, :sandbox]
  defstruct [:id, :port, :command, :policy, :sandbox]
end
