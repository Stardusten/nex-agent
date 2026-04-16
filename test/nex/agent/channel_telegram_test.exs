defmodule Nex.Agent.Channel.TelegramTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Config}
  alias Nex.Agent.Channel.Telegram

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    parent = self()

    http_get_fun = fn url, params, _opts ->
      send(parent, {:http_get, url, params})

      cond do
        String.ends_with?(url, "/getUpdates") ->
          {:ok,
           %{
             "ok" => true,
             "result" => [
               %{
                 "update_id" => 1001,
                 "message" => %{
                   "message_id" => 77,
                   "chat" => %{"id" => 123},
                   "from" => %{"id" => 456, "username" => "fenix"},
                   "photo" => [
                     %{"file_id" => "small", "width" => 90, "height" => 90, "file_size" => 1000},
                     %{
                       "file_id" => "large",
                       "width" => 1280,
                       "height" => 720,
                       "file_size" => 9000
                     }
                   ]
                 }
               }
             ]
           }}

        String.ends_with?(url, "/getFile") and params[:file_id] == "large" ->
          {:ok, %{"ok" => true, "result" => %{"file_path" => "photos/large.jpg"}}}

        String.ends_with?(url, "/getFile") and params[:file_id] == "doc-image" ->
          {:ok, %{"ok" => true, "result" => %{"file_path" => "docs/image.png"}}}

        true ->
          {:error, :unexpected}
      end
    end

    http_get_binary_fun = fn url, _opts ->
      send(parent, {:http_get_binary, url})

      cond do
        String.contains?(url, "/photos/large.jpg") ->
          {:ok, %{body: <<255, 216, 255>>}}

        String.contains?(url, "/docs/image.png") ->
          {:ok, %{body: <<137, 80, 78, 71, 13, 10, 26, 10>>}}

        true ->
          {:error, :unexpected}
      end
    end

    http_post_fun = fn url, body, _opts ->
      send(parent, {:http_post, url, body})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 999}}}
    end

    config = %Config{Config.default() | telegram: %{"enabled" => false}}
    name = String.to_atom("telegram_test_#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        {Telegram,
         name: name,
         config: config,
         http_get_fun: http_get_fun,
         http_get_binary_fun: http_get_binary_fun,
         http_post_fun: http_post_fun}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, token: "bot-token"}
    end)

    Bus.subscribe(:inbound)

    on_exit(fn ->
      Bus.unsubscribe(:inbound)
    end)

    {:ok, pid: pid}
  end

  test "poll converts photo-only message into inbound media", %{pid: pid} do
    send(pid, :poll)

    assert_receive {:http_get, url, _params}
    assert url =~ "/getUpdates"

    assert_receive {:http_get, file_url, params}
    assert file_url =~ "/getFile"
    assert params[:file_id] == "large"
    assert_receive {:http_get_binary, binary_url}
    assert binary_url =~ "/file/botbot-token/photos/large.jpg"

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.channel == "telegram"
    assert inbound.chat_id == "123"
    assert inbound.sender_id == "456|fenix"
    assert inbound.text == "[image]"
    assert inbound.attachments == []
    assert inbound.media_refs == []
    assert inbound.metadata["telegram_media_dropped"] == true
  end

  test "poll keeps caption and appends image marker for image documents", %{pid: pid} do
    :sys.replace_state(pid, fn state ->
      %{state | offset: nil}
    end)

    me = self()

    :sys.replace_state(pid, fn state ->
      http_get_fun = fn url, params, opts ->
        send(me, {:http_get_doc, url, params})

        cond do
          String.ends_with?(url, "/getUpdates") ->
            {:ok,
             %{
               "ok" => true,
               "result" => [
                 %{
                   "update_id" => 1002,
                   "message" => %{
                     "message_id" => 78,
                     "chat" => %{"id" => 124},
                     "from" => %{"id" => 457},
                     "caption" => "看看这个",
                     "document" => %{
                       "file_id" => "doc-image",
                       "mime_type" => "image/png"
                     }
                   }
                 }
               ]
             }}

          String.ends_with?(url, "/getFile") and params[:file_id] == "doc-image" ->
            {:ok, %{"ok" => true, "result" => %{"file_path" => "docs/image.png"}}}

          true ->
            state.http_get_fun.(url, params, opts)
        end
      end

      %{state | http_get_fun: http_get_fun}
    end)

    send(pid, :poll)

    assert_receive {:http_get_binary, binary_url}
    assert binary_url =~ "/file/botbot-token/docs/image.png"

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.chat_id == "124"
    assert inbound.sender_id == "457"
    assert inbound.text == "看看这个 [image]"
    assert inbound.attachments == []
    assert inbound.media_refs == []
    assert inbound.metadata["telegram_media_dropped"] == true
  end

  test "outbound long messages are chunked to telegram limit", %{pid: pid} do
    long_text = String.duplicate("a", 5000)

    send(
      pid,
      {:bus_message, :telegram_outbound, %{chat_id: "123", content: long_text, metadata: %{}}}
    )

    assert_receive {:http_post, url1, body1}
    assert url1 =~ "/sendMessage"
    assert String.length(body1[:text]) == 4096

    assert_receive {:http_post, url2, body2}
    assert url2 =~ "/sendMessage"
    assert String.length(body2[:text]) == 904
  end
end
