defmodule Nex.Agent.Sandbox.Command do
  @moduledoc """
  Platform-neutral command request for sandboxed child processes.
  """

  @type t :: %__MODULE__{
          program: String.t(),
          args: [String.t()],
          cwd: String.t(),
          env: %{optional(String.t()) => String.t()},
          stdin: String.t() | nil,
          timeout_ms: pos_integer(),
          cancel_ref: reference() | nil,
          metadata: map()
        }

  defstruct program: "",
            args: [],
            cwd: "",
            env: %{},
            stdin: nil,
            timeout_ms: 30_000,
            cancel_ref: nil,
            metadata: %{}

  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}), do: struct(__MODULE__, attrs)
end
