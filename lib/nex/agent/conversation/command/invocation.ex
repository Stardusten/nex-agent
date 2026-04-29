defmodule Nex.Agent.Conversation.Command.Invocation do
  @moduledoc """
  Canonical slash command invocation shared across text fallback and native IM entry points.
  """

  @enforce_keys [:name, :raw]
  defstruct [:name, :raw, args: [], source: :text]

  @type source :: :text | :native

  @type t :: %__MODULE__{
          name: String.t(),
          raw: String.t(),
          args: [String.t()],
          source: source()
        }
end
