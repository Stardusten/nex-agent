defmodule Nex.Agent.Inbound.Envelope do
  @moduledoc """
  Canonical inbound payload shared across channel adapters and InboundWorker.
  """

  alias Nex.Agent.Media.{Attachment, Ref}

  @type message_type :: :text | :image | :audio | :video | :file

  @enforce_keys [:channel, :chat_id, :sender_id, :text, :message_type, :raw, :metadata]
  defstruct [
    :channel,
    :chat_id,
    :sender_id,
    :user_id,
    :message_id,
    :text,
    :message_type,
    :raw,
    :metadata,
    media_refs: [],
    attachments: []
  ]

  @type t :: %__MODULE__{
          channel: String.t(),
          chat_id: String.t(),
          sender_id: String.t(),
          user_id: String.t() | nil,
          message_id: String.t() | nil,
          text: String.t(),
          message_type: message_type(),
          raw: map(),
          metadata: map(),
          media_refs: [Ref.t()],
          attachments: [Attachment.t()]
        }
end
