defmodule Nex.Agent.Interface.Media.Attachment do
  @moduledoc """
  Locally hydrated media attachment used as the model-input truth source.
  """

  @type kind :: :image | :audio | :video | :file
  @type source :: :inbound | :generated | :downloaded

  @enforce_keys [:id, :channel, :kind, :mime_type, :local_path, :source, :platform_ref]
  defstruct [
    :id,
    :channel,
    :kind,
    :mime_type,
    :filename,
    :local_path,
    :size_bytes,
    :source,
    :message_id,
    :platform_ref,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          channel: String.t(),
          kind: kind(),
          mime_type: String.t(),
          filename: String.t() | nil,
          local_path: String.t(),
          size_bytes: non_neg_integer() | nil,
          source: source(),
          message_id: String.t() | nil,
          platform_ref: map(),
          metadata: map()
        }

  @spec image?(t()) :: boolean()
  def image?(%__MODULE__{kind: :image}), do: true
  def image?(_), do: false

  @spec audio?(t()) :: boolean()
  def audio?(%__MODULE__{kind: :audio}), do: true
  def audio?(_), do: false

  @spec video?(t()) :: boolean()
  def video?(%__MODULE__{kind: :video}), do: true
  def video?(_), do: false

  @spec file?(t()) :: boolean()
  def file?(%__MODULE__{kind: :file}), do: true
  def file?(_), do: false
end
