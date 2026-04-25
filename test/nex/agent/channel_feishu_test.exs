defmodule Nex.Agent.Channel.FeishuTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Config}
  alias Nex.Agent.Channel.Feishu
  alias Nex.Agent.Channel.Feishu.StreamConverter
  alias Nex.Agent.Inbound.Envelope
  alias Nex.Agent.Media.Attachment

  @instance_id "feishu_test"

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    if Process.whereis(Nex.Agent.ChannelRegistry) == nil do
      start_supervised!(Nex.Agent.Channel.Registry)
    end

    parent = self()

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_123"}}}

        String.contains?(url, "/cardkit/v1/cards") ->
          {:ok, %{"code" => 0, "data" => %{"card_id" => "card_123"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_put_fun = fn url, body, headers ->
      send(parent, {:http_put, url, body, headers})

      if String.contains?(url, "/cardkit/v1/cards/") do
        {:ok, %{"code" => 0, "data" => %{}}}
      else
        {:ok, %{"code" => 1, "msg" => "unexpected put #{url}"}}
      end
    end

    http_get_fun = fn url, headers ->
      send(parent, {:http_get, url, headers})

      if String.contains?(url, "/im/v1/messages/") and String.contains?(url, "/resources/") do
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "image/png"}],
           body: <<137, 80, 78, 71, 13, 10, 26, 10>>
         }}
      else
        {:error, :unexpected}
      end
    end

    http_post_multipart_fun = fn url, body, headers ->
      send(parent, {:http_post_multipart, url, body, headers})

      if String.contains?(url, "/im/v1/images") do
        {:ok, %{"code" => 0, "data" => %{"image_key" => "img_uploaded"}}}
      else
        if String.contains?(url, "/im/v1/files") do
          {:ok, %{"code" => 0, "data" => %{"file_key" => "file_uploaded"}}}
        else
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
        end
      end
    end

    channel_config = %{
      "type" => "feishu",
      "enabled" => false,
      "app_id" => "cli_test",
      "app_secret" => "sec_test"
    }

    config = %Config{Config.default() | channel: %{@instance_id => channel_config}}

    pid =
      start_supervised!(
        {Feishu,
         instance_id: @instance_id,
         config: config,
         channel_config: channel_config,
         http_post_fun: http_post_fun,
         http_put_fun: http_put_fun,
         http_post_multipart_fun: http_post_multipart_fun,
         http_get_fun: http_get_fun}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    Bus.subscribe(:inbound)

    on_exit(fn ->
      Bus.unsubscribe(:inbound)
    end)

    {:ok, pid: pid}
  end

  test "legacy outbound defaults to interactive JSON 2.0 card", %{pid: _pid} do
    Bus.publish_sync({:channel_outbound, @instance_id}, %{
      chat_id: "ou_123",
      content: "hello world",
      metadata: %{}
    })

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages"
    assert body2["msg_type"] == "interactive"
    assert body2["receive_id"] == "ou_123"
    card = Jason.decode!(body2["content"])
    assert card["schema"] == "2.0"
    assert get_in(card, ["body", "elements", Access.at(0), "content"]) == "hello world"
  end

  test "explicit image msg_type sends raw feishu payload", %{pid: _pid} do
    Bus.publish_sync({:channel_outbound, @instance_id}, %{
      chat_id: "oc_chat_123",
      content: nil,
      metadata: %{
        "msg_type" => "image",
        "content_json" => %{"image_key" => "img_123"},
        "receive_id_type" => "chat_id"
      }
    })

    assert_receive {:http_post, _, _, _}
    assert_receive {:http_post, url, body, _headers}

    assert url =~ "receive_id_type=chat_id"
    assert body["msg_type"] == "image"
    assert Jason.decode!(body["content"]) == %{"image_key" => "img_123"}
  end

  test "synchronous send_message call confirms Feishu delivery", %{pid: pid} do
    assert :ok = GenServer.call(pid, {:send_message, "ou_123", "hello sync", %{}})

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages"
    assert body2["receive_id"] == "ou_123"
    assert body2["msg_type"] == "interactive"
    card = Jason.decode!(body2["content"])
    assert card["schema"] == "2.0"
    assert get_in(card, ["body", "elements", Access.at(0), "content"]) == "hello sync"
  end

  test "public send_card uses inline interactive JSON 2.0 card", %{pid: _pid} do
    assert {:ok, "om_123"} = Feishu.send_card(@instance_id, "ou_123", "hello card", %{})

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages"
    assert body2["msg_type"] == "interactive"
    card = Jason.decode!(body2["content"])
    assert card["schema"] == "2.0"
    assert get_in(card, ["body", "elements", Access.at(0), "content"]) == "hello card"
  end

  test "stream card uses CardKit create, card reference send, and element update", %{pid: _pid} do
    assert {:ok, %{message_id: "om_123", card_id: "card_123"}} =
             Feishu.open_stream_card(@instance_id, "ou_123", "hello stream", %{})

    assert_receive {:http_post, auth_url, _auth_body, _auth_headers}
    assert auth_url =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post, card_url, card_body, _headers}
    assert card_url =~ "/cardkit/v1/cards"
    assert card_body["type"] == "card_json"

    card = Jason.decode!(card_body["data"])
    assert card["schema"] == "2.0"
    assert get_in(card, ["config", "streaming_mode"]) == true
    assert get_in(card, ["body", "elements", Access.at(0), "element_id"]) == "content"

    assert_receive {:http_post, send_url, send_body, _headers}
    assert send_url =~ "/im/v1/messages"
    assert send_body["msg_type"] == "interactive"

    assert Jason.decode!(send_body["content"]) == %{
             "type" => "card",
             "data" => %{"card_id" => "card_123"}
           }

    assert :ok = Feishu.update_card(@instance_id, "card_123", "hello updated", 2)

    assert_receive {:http_put, put_url, put_body, _put_headers}
    assert put_url =~ "/cardkit/v1/cards/card_123/elements/content/content"
    assert put_body["content"] == "hello updated"
    assert put_body["sequence"] == 2
  end

  test "interactive JSON 2.0 card preserves markdown content", %{
    pid: _pid
  } do
    markdown = """
    # Title

    ```elixir
    IO.puts("hi")
    ```

    | name | score |
    | --- | --- |
    | alice | 10 |
    <newmsg/>
    next
    """

    assert {:ok, "om_123"} = Feishu.send_card(@instance_id, "ou_123", markdown, %{})

    assert_receive {:http_post, _auth_url, _auth_body, _auth_headers}
    assert_receive {:http_post, send_url, body, _headers}
    assert send_url =~ "/im/v1/messages"

    assert body["msg_type"] == "interactive"
    card = Jason.decode!(body["content"])
    assert card["schema"] == "2.0"
    assert is_list(get_in(card, ["body", "elements"]))
  end

  test "stream converter updates active card incrementally", %{pid: _pid} do
    assert {:ok, converter} = StreamConverter.start(@instance_id, "ou_123", %{})
    assert {:ok, converter} = StreamConverter.push_text(converter, "# Ti")
    assert {:ok, converter} = StreamConverter.push_text(converter, "tle")
    assert {:ok, converter} = StreamConverter.finish(converter)

    assert converter.completed
    assert converter.active_text == "# Title"
    assert converter.active_card_id == "card_123"
    assert converter.active_sequence == 3
  end

  test "stream converter creates new card immediately after newmsg boundary", %{pid: _pid} do
    drain_http_posts()
    drain_http_posts_multipart()
    _ = collect_http_puts([])

    assert {:ok, converter} = StreamConverter.start(@instance_id, "ou_123", %{})
    assert {:ok, converter} = StreamConverter.push_text(converter, "first\n\n<newmsg/>\n\nsec")

    # New card for "sec" should already be created (no deferral)
    posts_after_push = collect_http_posts([])

    card_creates_after_push =
      Enum.filter(posts_after_push, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)

    assert length(card_creates_after_push) >= 2

    assert {:ok, converter2} = StreamConverter.push_text(converter, "ond")
    assert {:ok, _finished} = StreamConverter.finish(converter2)

    posts = posts_after_push ++ collect_http_posts([])
    card_creates = Enum.filter(posts, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)

    card_sends =
      Enum.filter(posts, fn {url, body} ->
        url =~ "/im/v1/messages" and body["msg_type"] == "interactive"
      end)

    puts = collect_http_puts([])

    assert length(card_creates) >= 2
    assert length(card_sends) >= 2

    assert Enum.any?(card_creates, fn {_url, body} ->
             body["data"]
             |> Jason.decode!()
             |> get_in(["body", "elements", Access.at(0), "content"]) == "Thinking..."
           end)

    refute Enum.any?(puts, fn {_url, body} ->
             is_binary(body["content"]) and body["content"] =~ "<newmsg/>"
           end)
  end

  test "synchronous local image send uploads and delivers native image message", %{pid: pid} do
    path =
      Path.join(System.tmp_dir!(), "feishu_test_image_#{System.unique_integer([:positive])}.png")

    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

    on_exit(fn -> File.rm(path) end)

    assert :ok = GenServer.call(pid, {:send_local_image, "ou_123", path, %{}})

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post_multipart, upload_url, multipart_body, upload_headers}
    assert upload_url =~ "/im/v1/images"

    assert Enum.any?(upload_headers, fn {key, value} ->
             key == "Authorization" and value =~ "Bearer "
           end)

    assert Keyword.get(multipart_body, :image_type) == "message"

    posts = collect_http_posts([])

    {url2, body2} =
      Enum.find(posts, fn {url, body} ->
        url =~ "/im/v1/messages" and body["msg_type"] == "image"
      end)

    assert url2 =~ "/im/v1/messages"
    assert body2["msg_type"] == "image"
    assert Jason.decode!(body2["content"]) == %{"image_key" => "img_uploaded"}
  end

  test "attachment send preserves explicit receive_id_type for native media messages", %{
    pid: _pid
  } do
    path =
      Path.join(System.tmp_dir!(), "feishu_chat_target_#{System.unique_integer([:positive])}.png")

    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>>)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, ["image"]} =
             Feishu.deliver_outbound(%Nex.Agent.Outbound.Message{
               channel: @instance_id,
               chat_id: "oc_chat_target",
               attachments: [
                 %Attachment{
                   id: "out_chat_target",
                   channel: @instance_id,
                   kind: :image,
                   mime_type: "image/png",
                   filename: "chat-target.png",
                   local_path: path,
                   size_bytes: 8,
                   source: :generated,
                   platform_ref: %{},
                   metadata: %{}
                 }
               ],
               metadata: %{"receive_id_type" => "chat_id"}
             })

    assert_receive {:http_post, auth_url, _auth_body, _auth_headers}
    assert auth_url =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post_multipart, upload_url, _multipart_body, _headers}
    assert upload_url =~ "/im/v1/images"

    posts = collect_http_posts([])

    {send_url, body} =
      Enum.find(posts, fn {url, body} ->
        url =~ "/im/v1/messages" and body["msg_type"] == "image"
      end)

    assert send_url =~ "receive_id_type=chat_id"
    assert body["receive_id"] == "oc_chat_target"
  end

  test "outbound file audio and video attachments use files upload and native msg types", %{
    pid: _pid
  } do
    for {kind, expected_type} <- [file: "file", audio: "audio", video: "media"] do
      path =
        Path.join(
          System.tmp_dir!(),
          "feishu_#{kind}_#{System.unique_integer([:positive])}.bin"
        )

      File.write!(path, "payload")

      attachment = %Attachment{
        id: "out_#{kind}",
        channel: @instance_id,
        kind: kind,
        mime_type: "application/octet-stream",
        filename: "#{kind}.bin",
        local_path: path,
        size_bytes: 7,
        source: :generated,
        platform_ref: %{},
        metadata: %{}
      }

      assert {:ok, [returned_kind]} =
               Feishu.deliver_outbound(%Nex.Agent.Outbound.Message{
                 channel: @instance_id,
                 chat_id: "ou_media",
                 attachments: [attachment],
                 metadata: %{}
               })

      assert returned_kind == Atom.to_string(kind)

      assert_receive {:http_post_multipart, upload_url, multipart_body, _headers}
      assert upload_url =~ "/im/v1/files"
      assert Keyword.get(multipart_body, :file_type) == "message"

      posts = collect_http_posts([])

      {_send_url, body} =
        Enum.find(posts, fn {url, body} ->
          url =~ "/im/v1/messages" and body["msg_type"] == expected_type
        end)

      assert body["msg_type"] == expected_type

      on_exit(fn -> File.rm(path) end)
      drain_http_posts()
      drain_http_posts_multipart()
    end
  end

  test "progress payloads are ignored instead of being sent to feishu", %{pid: _pid} do
    drain_http_posts()

    Bus.publish_sync({:channel_outbound, @instance_id}, %{
      chat_id: "ou_123",
      content: "内部进度",
      metadata: %{"_progress" => true}
    })

    posts = collect_http_posts([])

    refute Enum.any?(posts, fn {url, body} ->
             String.contains?(url, "/im/v1/messages") and
               Map.get(body, "receive_id") == "ou_123" and
               to_string(Map.get(body, "content", "")) =~ "内部进度"
           end)
  end

  test "ingest_event keeps structured normalized metadata for location messages", %{pid: pid} do
    payload = %{
      "event" => %{
        "sender" => %{
          "sender_id" => %{"open_id" => "ou_sender"},
          "sender_type" => "user"
        },
        "message" => %{
          "message_id" => "om_loc",
          "chat_id" => "oc_group",
          "chat_type" => "group",
          "message_type" => "location",
          "content" =>
            Jason.encode!(%{
              "name" => "Shanghai Tower",
              "longitude" => "121.499",
              "latitude" => "31.239"
            })
        }
      }
    }

    assert :ok = GenServer.call(pid, {:ingest_event, payload})

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.channel == @instance_id
    assert inbound.metadata["channel_type"] == "feishu"
    assert inbound.text =~ "Shanghai Tower"
    assert inbound.metadata["message_type"] == "location"
    assert inbound.metadata["raw_content_json"]["name"] == "Shanghai Tower"
    assert inbound.metadata["normalized_content"]["card"]["longitude"] == "121.499"
  end

  defp drain_http_posts do
    receive do
      {:http_post, _url, _body, _headers} ->
        drain_http_posts()
    after
      0 ->
        :ok
    end
  end

  defp collect_http_posts(acc) do
    receive do
      {:http_post, url, body, _headers} ->
        collect_http_posts([{url, body} | acc])
    after
      150 ->
        Enum.reverse(acc)
    end
  end

  defp drain_http_posts_multipart do
    receive do
      {:http_post_multipart, _url, _body, _headers} ->
        drain_http_posts_multipart()
    after
      0 ->
        :ok
    end
  end

  defp collect_http_puts(acc) do
    receive do
      {:http_put, url, body, _headers} ->
        collect_http_puts([{url, body} | acc])
    after
      150 ->
        Enum.reverse(acc)
    end
  end

  test "ingest_event extracts post resources into metadata", %{pid: pid} do
    payload = %{
      "event" => %{
        "sender" => %{
          "sender_id" => %{"open_id" => "ou_sender"},
          "sender_type" => "user"
        },
        "message" => %{
          "message_id" => "om_post",
          "chat_id" => "ou_sender",
          "chat_type" => "p2p",
          "message_type" => "post",
          "content" =>
            Jason.encode!(%{
              "zh_cn" => %{
                "title" => "Title",
                "content" => [
                  [
                    %{"tag" => "text", "text" => "hello"},
                    %{"tag" => "a", "text" => "link", "href" => "https://example.com"}
                  ],
                  [
                    %{"tag" => "img", "image_key" => "img_post_1"}
                  ]
                ]
              }
            })
        }
      }
    }

    assert :ok = GenServer.call(pid, {:ingest_event, payload})

    assert_receive {:bus_message, :inbound, inbound}
    assert %Envelope{} = inbound
    assert inbound.metadata["message_type"] == "post"
    assert inbound.text =~ "Title"
    assert inbound.text =~ "link(https://example.com)"
    assert [%Attachment{}] = inbound.attachments
    assert Enum.all?(inbound.attachments, &File.exists?(&1.local_path))
    assert inbound.media_refs == []
  end

  test "ingest_event hydrates image messages into media payloads", %{pid: pid} do
    payload = %{
      "event" => %{
        "sender" => %{
          "sender_id" => %{"open_id" => "ou_sender"},
          "sender_type" => "user"
        },
        "message" => %{
          "message_id" => "om_img",
          "chat_id" => "ou_sender",
          "chat_type" => "p2p",
          "message_type" => "image",
          "content" => Jason.encode!(%{"image_key" => "img_abc"})
        }
      }
    }

    assert :ok = GenServer.call(pid, {:ingest_event, payload})

    assert_receive {:http_get, url, headers}
    assert url =~ "/im/v1/messages/om_img/resources/img_abc?type=image"

    assert Enum.any?(headers, fn {key, value} -> key == "Authorization" and value =~ "Bearer " end)

    assert_receive {:bus_message, :inbound, inbound}
    assert %Envelope{} = inbound
    assert inbound.metadata["message_type"] == "image"
    assert inbound.media_refs == []

    assert [%Attachment{platform_ref: %{"image_key" => "img_abc"}, mime_type: "image/png"}] =
             inbound.attachments

    assert Enum.all?(inbound.attachments, &File.exists?(&1.local_path))
  end

  test "ingest_event accepts top-level post content without locale wrapper", %{pid: pid} do
    payload = %{
      "event" => %{
        "sender" => %{
          "sender_id" => %{"open_id" => "ou_sender"},
          "sender_type" => "user"
        },
        "message" => %{
          "message_id" => "om_post_flat",
          "chat_id" => "ou_sender",
          "chat_type" => "p2p",
          "message_type" => "post",
          "content" =>
            Jason.encode!(%{
              "title" => "",
              "content" => [
                [%{"tag" => "img", "image_key" => "img_flat_1"}],
                [%{"tag" => "text", "text" => "你好"}]
              ]
            })
        }
      }
    }

    assert :ok = GenServer.call(pid, {:ingest_event, payload})

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.metadata["message_type"] == "post"
    assert inbound.text =~ "你好"
    assert inbound.text =~ "[image]"
    assert [%Attachment{}] = inbound.attachments
    assert inbound.media_refs == []
  end
end
