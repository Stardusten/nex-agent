defmodule Nex.Agent.Interface.Outbound.Message do
  @moduledoc """
  Canonical outbound request shared by tools and channel senders.
  """

  alias Nex.Agent.Interface.Media.Attachment

  @enforce_keys [:channel, :chat_id]
  defstruct [
    :channel,
    :chat_id,
    :text,
    :native_type,
    :native_payload,
    attachments: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          channel: String.t(),
          chat_id: String.t(),
          text: String.t() | nil,
          native_type: String.t() | nil,
          native_payload: map() | nil,
          attachments: [Attachment.t()],
          metadata: map()
        }
end
