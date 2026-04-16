defmodule Nex.Agent.Stream.Event do
  @moduledoc false

  @enforce_keys [:seq, :run_id, :type]
  defstruct [
    :seq,
    :run_id,
    :type,
    :content,
    :name,
    :tool_call_id,
    data: %{}
  ]

  @type event_type ::
          :message_start
          | :text_delta
          | :text_commit
          | :tool_call_start
          | :tool_call_result
          | :tool_call_end
          | :message_end
          | :error

  @type t :: %__MODULE__{
          seq: pos_integer(),
          run_id: String.t(),
          type: event_type(),
          content: String.t() | nil,
          name: String.t() | nil,
          tool_call_id: String.t() | nil,
          data: map()
        }
end
