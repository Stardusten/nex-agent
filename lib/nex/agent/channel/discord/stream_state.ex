defmodule Nex.Agent.Channel.Discord.StreamState do
  @moduledoc false

  alias Nex.Agent.Channel.Discord.StreamConverter

  defstruct [
    :converter,
    :flush_timer_ref,
    :thinking_timer_ref,
    :typing_timer_ref,
    :status_timer_ref,
    pending_text: ""
  ]

  @type t :: %__MODULE__{
          converter: StreamConverter.t(),
          flush_timer_ref: reference() | nil,
          thinking_timer_ref: reference() | nil,
          typing_timer_ref: reference() | nil,
          status_timer_ref: reference() | nil,
          pending_text: String.t()
        }
end
