defmodule Nex.Agent.Media.Projector do
  @moduledoc """
  Projects hydrated attachments into provider-facing multimodal content items.
  """

  alias Nex.Agent.Media.Attachment

  @spec project_for_model([Attachment.t()] | nil, keyword()) :: [map()]
  def project_for_model(nil, _opts), do: []
  def project_for_model([], _opts), do: []

  def project_for_model(attachments, _opts) do
    Enum.flat_map(attachments, fn
      %Attachment{kind: :image, local_path: path, mime_type: mime_type} ->
        [
          %{
            "type" => "image",
            "source" => %{
              "type" => "file",
              "path" => path,
              "media_type" => mime_type
            }
          }
        ]

      %Attachment{kind: kind, filename: filename} ->
        [
          %{
            "type" => "text",
            "text" => "[User sent #{kind}: #{filename || "attachment"}]"
          }
        ]
    end)
  end
end
