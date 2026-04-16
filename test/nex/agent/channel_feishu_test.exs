defmodule Nex.Agent.Channel.FeishuTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Config}
  alias Nex.Agent.Channel.Feishu
  alias Nex.Agent.Inbound.Envelope
  alias Nex.Agent.Media.Attachment
  alias Nex.Agent.Stream.{FeishuSession, Result, Transport}

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    parent = self()

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_123"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_patch_fun = fn url, body, headers ->
      send(parent, {:http_patch, url, body, headers})

      if String.contains?(url, "/im/v1/messages/") do
        {:ok, %{"code" => 0, "data" => %{}}}
      else
        {:ok, %{"code" => 1, "msg" => "unexpected"}}
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
        {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    config = %Config{Config.default() | feishu: %{"enabled" => false}}

    pid =
      start_supervised!(
        {Feishu,
         config: config,
         http_post_fun: http_post_fun,
         http_patch_fun: http_patch_fun,
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

  test "legacy outbound still defaults to interactive card", %{pid: _pid} do
    Bus.publish_sync(:feishu_outbound, %{
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
    assert is_binary(body2["content"])
  end

  test "explicit image msg_type sends raw feishu payload", %{pid: _pid} do
    Bus.publish_sync(:feishu_outbound, %{
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
    assert is_binary(body2["content"])
  end

  test "public send_card and update_card patch the same carrier", %{pid: _pid} do
    assert {:ok, "om_123"} = Feishu.send_card("ou_123", "hello card", %{})

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages"
    assert body2["msg_type"] == "interactive"

    assert :ok = Feishu.update_card("om_123", "hello updated")

    assert_receive {:http_patch, patch_url, patch_body, _patch_headers}
    assert patch_url =~ "/im/v1/messages/om_123"
    assert is_binary(patch_body["content"])
    assert patch_body["content"] =~ "hello updated"
  end

  test "interactive card rendering preserves code block table and new message separator", %{
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

    assert {:ok, "om_123"} = Feishu.send_card("ou_123", markdown, %{})

    assert_receive {:http_post, _auth_url, _auth_body, _auth_headers}
    assert_receive {:http_post, send_url, body, _headers}
    assert send_url =~ "/im/v1/messages"

    card = Jason.decode!(body["content"])
    assert card["config"]["wide_screen_mode"] == true

    elements = card["elements"]

    assert Enum.any?(elements, fn
             %{"text" => %{"content" => content}} ->
               content == "**Title**" or
                 content == "```elixir\nIO.puts(\"hi\")\n```" or
                 content == "| name | score |\n| --- | --- |\n| alice | 10 |" or
                 content == "next"

             _ ->
               false
           end)

    assert Enum.any?(elements, &(&1 == %{"tag" => "hr"}))
  end

  test "feishu session finalize_success patches final markdown content", %{pid: _pid} do
    {:ok, %FeishuSession{} = session} =
      Transport.open_session(
        {:workspace, "feishu:ou_123"},
        "feishu",
        "ou_123",
        %{metadata: %{}, channel_runtime: %{"streaming" => true}}
      )

    streamed_session = %FeishuSession{session | visible_text: "#Title", user_visible: true}
    result = Result.ok("run_1", "# Title\n\n- item 1\n- item 2\n")

    {final_session, actions, handled?} = Transport.finalize_success(streamed_session, result)

    assert handled?
    assert final_session.completed
    assert final_session.visible_text == "# Title\n\n- item 1\n- item 2"
    assert actions == [{:update_card, "om_123", "# Title\n\n- item 1\n- item 2"}]
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

    assert_receive {:http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages"
    assert body2["msg_type"] == "image"
    assert Jason.decode!(body2["content"]) == %{"image_key" => "img_uploaded"}
  end

  test "progress payloads are ignored instead of being sent to feishu", %{pid: _pid} do
    drain_http_posts()

    Bus.publish_sync(:feishu_outbound, %{
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
    assert inbound.channel == "feishu"
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
    assert [%Attachment{platform_ref: %{"image_key" => "img_abc"}, mime_type: "image/png"}] = inbound.attachments
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
