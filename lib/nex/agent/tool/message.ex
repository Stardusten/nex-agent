defmodule Nex.Agent.Tool.Message do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Media.Attachment
  alias Nex.Agent.Outbound
  alias Nex.Agent.Outbound.Message, as: OutboundMessage

  def name, do: "message"
  def description, do: "Send a message to the user immediately."
  def category, do: :base

  def definition do
    %{
      name: "message",
      description:
        "Send a message to the user. Use this when you want to communicate something immediately. For Feishu, you can send structured native message types by providing msg_type plus content_json, or send attachments by providing attachment_path/attachment_kind or attachment_paths/attachment_kinds.",
      parameters: %{
        type: "object",
        properties: %{
          content: %{type: "string", description: "The message content to send"},
          msg_type: %{
            type: "string",
            description:
              "Optional explicit message type for channels that support structured messages, such as Feishu. Feishu examples: text, post, interactive, image, file, audio, media, sticker, share_chat, share_user, system."
          },
          content_json: %{
            type: ["object", "string"],
            description:
              "Optional structured message payload. For Feishu this should be the raw content JSON object/string for the specified msg_type. Examples: image => {image_key}, file/audio/media/sticker => {file_key}, share_chat => {chat_id}, share_user => {user_id}, text => {text}, system => {type, params}."
          },
          attachment_path: %{
            type: "string",
            description:
              "Optional absolute or workspace-relative path to a local attachment. Requires attachment_kind."
          },
          attachment_kind: %{
            type: "string",
            description:
              "Attachment kind for attachment_path. Allowed values: image, file, audio, video."
          },
          attachment_paths: %{
            type: "array",
            items: %{type: "string"},
            description:
              "Optional list of absolute or workspace-relative attachment paths. Use together with attachment_kinds."
          },
          attachment_kinds: %{
            type: "array",
            items: %{type: "string"},
            description:
              "Optional list of attachment kinds aligned by index with attachment_paths. Allowed values: image, file, audio, video."
          },
          local_image_path: %{
            type: "string",
            description:
              "Deprecated compatibility input. Internally normalized to attachment_path + attachment_kind=image."
          },
          receive_id_type: %{
            type: "string",
            description:
              "Optional explicit recipient ID type for Feishu (open_id, chat_id, user_id, union_id, email)."
          },
          channel: %{
            type: "string",
            description:
              "Target channel (telegram, feishu, discord, http). Defaults to current channel."
          },
          chat_id: %{
            type: "string",
            description: "Target chat/user ID. Defaults to current chat."
          }
        },
        description:
          "Provide at least one of content, content_json, attachment_path, attachment_paths, or local_image_path.",
        required: []
      }
    }
  end

  def execute(args, ctx) do
    require Logger
    Logger.info("Message Tool Execute - Args: #{inspect(args)}, Ctx: #{inspect(ctx)}")

    with {:ok, outbound} <- from_tool_args(args, ctx) do
      case outbound.channel do
        "feishu" ->
          if Process.whereis(Nex.Agent.Channel.Feishu) do
            case Nex.Agent.Channel.Feishu.deliver_outbound(outbound) do
              {:ok, delivered} ->
                {:ok,
                 %{sent: true, channel: outbound.channel, chat_id: outbound.chat_id}
                 |> maybe_put_result(:delivered, delivered)}

              {:error, reason} ->
                {:error, "Feishu send failed: #{inspect(reason)}"}
            end
          else
            publish_outbound(outbound)
            {:ok, %{sent: true, channel: outbound.channel, chat_id: outbound.chat_id}}
          end

        _ ->
          if outbound.attachments != [] do
            {:error, "attachments are currently only supported for Feishu"}
          else
            publish_outbound(outbound)
            {:ok, %{sent: true, channel: outbound.channel, chat_id: outbound.chat_id}}
          end
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec from_tool_args(map(), map()) :: {:ok, OutboundMessage.t()} | {:error, term()}
  def from_tool_args(args, ctx) do
    args = normalize_legacy_attachment_args(args)

    channel = Map.get(args, "channel") || Map.get(ctx, :channel, "telegram")
    chat_id = Map.get(args, "chat_id") || Map.get(ctx, :chat_id, "")
    content = normalize_optional_text(Map.get(args, "content"))
    msg_type = Map.get(args, "msg_type")
    content_json = Map.get(args, "content_json")
    receive_id_type = Map.get(args, "receive_id_type")

    metadata =
      Map.get(ctx, :metadata, %{})
      |> Map.put("_from_tool", true)
      |> maybe_put("receive_id_type", receive_id_type)

    with {:ok, attachments} <- attachments_from_args(args, channel, ctx),
         {:ok, native_payload} <- normalize_native_payload(content_json),
         :ok <- validate_request(content, native_payload, attachments) do
      {:ok,
       %OutboundMessage{
         channel: channel,
         chat_id: chat_id,
         text: content,
         native_type: msg_type,
         native_payload: native_payload,
         attachments: attachments,
         metadata: metadata
       }}
    end
  end

  defp publish_outbound(%OutboundMessage{} = outbound) do
    topic = Outbound.topic_for_channel(outbound.channel)

    payload = %{
      chat_id: outbound.chat_id,
      content: outbound.text,
      metadata:
        outbound.metadata
        |> maybe_put("msg_type", outbound.native_type)
        |> maybe_put("content_json", outbound.native_payload)
    }

    Nex.Agent.Bus.publish(topic, payload)
  end

  defp attachments_from_args(args, channel, ctx) do
    single_path = Map.get(args, "attachment_path")
    single_kind = Map.get(args, "attachment_kind")
    paths = Map.get(args, "attachment_paths")
    kinds = Map.get(args, "attachment_kinds")

    cond do
      is_binary(single_path) and single_path != "" ->
        with {:ok, kind} <- parse_attachment_kind(single_kind),
             {:ok, attachment} <- build_attachment(single_path, kind, channel, ctx) do
          {:ok, [attachment]}
        end

      is_list(paths) and paths != [] ->
        with true <-
               is_list(kinds) and length(paths) == length(kinds) or
                 {:error, :attachment_kinds_must_align},
             {:ok, attachments} <- build_attachment_list(paths, kinds, channel, ctx) do
          {:ok, attachments}
        end

      true ->
        {:ok, []}
    end
  end

  defp build_attachment_list(paths, kinds, channel, ctx) do
    Enum.zip(paths, kinds)
    |> Enum.reduce_while({:ok, []}, fn {path, kind}, {:ok, acc} ->
      with {:ok, parsed_kind} <- parse_attachment_kind(kind),
           {:ok, attachment} <- build_attachment(path, parsed_kind, channel, ctx) do
        {:cont, {:ok, acc ++ [attachment]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_attachment(path, kind, channel, ctx) when is_binary(path) do
    expanded_path = expand_attachment_path(path, ctx)

    cond do
      not File.exists?(expanded_path) ->
        {:error, {:attachment_not_found, expanded_path}}

      not File.regular?(expanded_path) ->
        {:error, {:attachment_not_regular_file, expanded_path}}

      true ->
        stat = File.stat!(expanded_path)

        {:ok,
         %Attachment{
           id: "out_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
           channel: channel,
           kind: kind,
           mime_type: MIME.from_path(expanded_path) || default_mime_type(kind),
           filename: Path.basename(expanded_path),
           local_path: expanded_path,
           size_bytes: stat.size,
           source: :generated,
           platform_ref: %{},
           metadata: %{}
         }}
    end
  end

  defp normalize_native_payload(nil), do: {:ok, nil}
  defp normalize_native_payload(payload) when is_map(payload), do: {:ok, payload}

  defp normalize_native_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, other} -> {:error, {:invalid_content_json, other}}
      {:error, reason} -> {:error, {:invalid_content_json, reason}}
    end
  end

  defp normalize_native_payload(other), do: {:error, {:invalid_content_json, other}}

  defp parse_attachment_kind("image"), do: {:ok, :image}
  defp parse_attachment_kind("file"), do: {:ok, :file}
  defp parse_attachment_kind("audio"), do: {:ok, :audio}
  defp parse_attachment_kind("video"), do: {:ok, :video}
  defp parse_attachment_kind(kind) when kind in [:image, :file, :audio, :video], do: {:ok, kind}
  defp parse_attachment_kind(_), do: {:error, :invalid_attachment_kind}

  defp normalize_legacy_attachment_args(args) do
    case Map.get(args, "local_image_path") do
      path when is_binary(path) and path != "" ->
        args
        |> Map.put_new("attachment_path", path)
        |> Map.put_new("attachment_kind", "image")

      _ ->
        args
    end
  end

  defp validate_request(content, native_payload, attachments) do
    if not is_nil(content) or not is_nil(native_payload) or attachments != [] do
      :ok
    else
      {:error, "content, content_json, attachment_path(s), or local_image_path is required"}
    end
  end

  defp normalize_optional_text(text) when is_binary(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: nil, else: text
  end

  defp normalize_optional_text(_), do: nil

  defp default_mime_type(:image), do: "image/jpeg"
  defp default_mime_type(:file), do: "application/octet-stream"
  defp default_mime_type(:audio), do: "audio/mpeg"
  defp default_mime_type(:video), do: "video/mp4"

  defp expand_attachment_path(path, ctx) do
    cond do
      Path.type(path) == :absolute ->
        Path.expand(path)

      is_binary(Map.get(ctx, :workspace)) and Map.get(ctx, :workspace) != "" ->
        Path.expand(path, Map.get(ctx, :workspace))

      is_binary(Map.get(ctx, :cwd)) and Map.get(ctx, :cwd) != "" ->
        Path.expand(path, Map.get(ctx, :cwd))

      true ->
        Path.expand(path)
    end
  end

  defp maybe_put_result(map, _key, nil), do: map
  defp maybe_put_result(map, key, value), do: Map.put(map, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
