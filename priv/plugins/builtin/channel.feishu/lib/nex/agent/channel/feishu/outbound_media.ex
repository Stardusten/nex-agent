defmodule Nex.Agent.Channel.Feishu.OutboundMedia do
  @moduledoc false

  alias Nex.Agent.Interface.Media.Attachment

  @type materialized :: %{
          kind: :image | :file | :audio | :video,
          msg_type: String.t(),
          payload: map(),
          attachment: Attachment.t()
        }

  @spec materialize([Attachment.t()], keyword()) :: {:ok, [materialized()]} | {:error, term()}
  def materialize(attachments, opts) when is_list(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
      case materialize_attachment(attachment, opts) do
        {:ok, item} -> {:cont, {:ok, acc ++ [item]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp materialize_attachment(%Attachment{kind: :image} = attachment, opts) do
    upload_image_fun = Keyword.fetch!(opts, :upload_image_fun)

    with {:ok, image_key} <- upload_image_fun.(attachment) do
      {:ok,
       %{
         kind: :image,
         msg_type: "image",
         payload: %{"image_key" => image_key},
         attachment: attachment
       }}
    end
  end

  defp materialize_attachment(%Attachment{kind: kind} = attachment, opts)
       when kind in [:file, :audio, :video] do
    upload_file_fun = Keyword.fetch!(opts, :upload_file_fun)

    with {:ok, file_key} <- upload_file_fun.(attachment) do
      {:ok,
       %{
         kind: kind,
         msg_type: msg_type_for(kind),
         payload: %{"file_key" => file_key},
         attachment: attachment
       }}
    end
  end

  defp msg_type_for(:file), do: "file"
  defp msg_type_for(:audio), do: "audio"
  defp msg_type_for(:video), do: "media"
end
