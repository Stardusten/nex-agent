defmodule Nex.Agent.Sandbox.Result do
  @moduledoc """
  Completed sandbox execution result.
  """

  @type status :: :ok | :exit | :timeout | :cancelled | :denied | :error

  @type t :: %__MODULE__{
          status: status(),
          exit_code: non_neg_integer() | nil,
          stdout: String.t(),
          stderr: String.t(),
          duration_ms: non_neg_integer(),
          sandbox: map(),
          error: String.t() | nil
        }

  defstruct status: :error,
            exit_code: nil,
            stdout: "",
            stderr: "",
            duration_ms: 0,
            sandbox: %{},
            error: nil

  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}), do: struct(__MODULE__, attrs)
end
