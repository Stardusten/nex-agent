defmodule Nex.Agent.Interface.Media.Store do
  @moduledoc """
  Assigns storage paths for inbound media and persists binaries locally.
  """

  alias Nex.Agent.Interface.Media.Attachment

  @spec put_binary(binary(), keyword()) :: {:ok, Attachment.t()} | {:error, term()}
  def put_binary(binary, opts) when is_binary(binary) do
    attachment = build_attachment(binary, opts)
    File.mkdir_p!(Path.dirname(attachment.local_path))

    case File.write(attachment.local_path, binary) do
      :ok -> {:ok, attachment}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  @spec media_dir(keyword()) :: String.t()
  def media_dir(opts \\ []) do
    base_dir =
      case Keyword.get(opts, :workspace) do
        workspace when is_binary(workspace) and workspace != "" -> Path.expand(workspace)
        _ -> System.tmp_dir!() |> Path.join("nex-agent")
      end

    day = Date.utc_today() |> Date.to_iso8601()
    Path.join([base_dir, "media", "inbound", day])
  end

  defp build_attachment(binary, opts) do
    mime_type = Keyword.get(opts, :mime_type, "application/octet-stream")
    filename = Keyword.get(opts, :filename)
    channel = Keyword.fetch!(opts, :channel)
    kind = Keyword.fetch!(opts, :kind)
    source = Keyword.get(opts, :source, :inbound)
    message_id = Keyword.get(opts, :message_id)
    platform_ref = Keyword.get(opts, :platform_ref, %{})
    metadata = Keyword.get(opts, :metadata, %{})
    id = "media_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    ext = filename_extension(filename, mime_type)
    local_path = Path.join(media_dir(opts), id <> ext)

    %Attachment{
      id: id,
      channel: channel,
      kind: kind,
      mime_type: mime_type,
      filename: filename,
      local_path: local_path,
      size_bytes: byte_size(binary),
      source: source,
      message_id: message_id,
      platform_ref: platform_ref,
      metadata: metadata
    }
  end

  defp filename_extension(filename, _mime_type) when is_binary(filename) do
    case Path.extname(filename) do
      "" -> ""
      ext -> ext
    end
  end

  defp filename_extension(_filename, mime_type) do
    MIME.extensions(mime_type)
    |> List.first()
    |> case do
      nil -> ""
      ext -> "." <> ext
    end
  end
end
