defmodule Nex.Agent.Interface.Media.Ref do
  @moduledoc """
  Platform-native media reference before local hydration.
  """

  @type kind :: :image | :audio | :video | :file

  @enforce_keys [:channel, :kind, :platform_ref]
  defstruct [
    :channel,
    :kind,
    :message_id,
    :mime_type,
    :filename,
    :platform_ref,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          channel: String.t(),
          kind: kind(),
          message_id: String.t() | nil,
          mime_type: String.t() | nil,
          filename: String.t() | nil,
          platform_ref: map(),
          metadata: map()
        }
end
