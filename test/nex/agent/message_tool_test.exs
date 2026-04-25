defmodule Nex.Agent.MessageToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Bus
  alias Nex.Agent.Channel.Feishu
  alias Nex.Agent.Config
  alias Nex.Agent.Tool.Message
  alias Nex.Agent.Tool.Registry

  @instance_id "feishu_kai"
  @topic {:channel_outbound, @instance_id}

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    if Process.whereis(Nex.Agent.ChannelRegistry) == nil do
      start_supervised!(Nex.Agent.Channel.Registry)
    end

    if Process.whereis(Nex.Agent.Tool.Registry) == nil do
      start_supervised!({Registry, name: Registry})
    end

    Bus.subscribe(@topic)

    on_exit(fn ->
      Bus.unsubscribe(@topic)
    end)

    :ok
  end

  test "message tool preserves legacy behavior with plain content" do
    assert {:ok, %{sent: true, channel: @instance_id, chat_id: "ou_123"}} =
             Message.execute(
               %{"content" => "hello", "channel" => @instance_id, "chat_id" => "ou_123"},
               %{}
             )

    assert_receive {:bus_message, @topic, payload}
    assert payload.content == "hello"
    assert payload.metadata["_from_tool"] == true
    refute Map.has_key?(payload.metadata, "msg_type")
  end

  test "follow-up tool surface stays read-only and includes interrupt_session" do
    names =
      Registry.definitions(:follow_up)
      |> Enum.map(& &1["name"])
      |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new([
               "executor_status",
               "interrupt_session",
               "memory_status",
               "observe",
               "read",
               "skill_discover",
               "skill_get",
               "tool_list",
               "web_fetch",
               "web_search"
             ]),
             names
           )

    refute MapSet.member?(names, "bash")
    refute MapSet.member?(names, "edit")
    refute MapSet.member?(names, "write")
    refute MapSet.member?(names, "message")
    refute MapSet.member?(names, "spawn_task")
    refute MapSet.member?(names, "cron")
    refute MapSet.member?(names, "memory_write")
  end

  test "message tool forwards explicit feishu structured message metadata" do
    assert {:ok, %{sent: true, channel: @instance_id, chat_id: "oc_123"}} =
             Message.execute(
               %{
                 "channel" => @instance_id,
                 "chat_id" => "oc_123",
                 "msg_type" => "image",
                 "content_json" => %{"image_key" => "img_123"},
                 "receive_id_type" => "chat_id"
               },
               %{}
             )

    assert_receive {:bus_message, @topic, payload}
    assert payload.content == nil
    assert payload.metadata["msg_type"] == "image"
    assert payload.metadata["content_json"] == %{"image_key" => "img_123"}
    assert payload.metadata["receive_id_type"] == "chat_id"
  end

  test "message tool uses synchronous Feishu delivery when default channel process is running" do
    parent = self()

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_sync"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_post_multipart_fun = fn url, body, headers ->
      send(parent, {:http_post_multipart, url, body, headers})

      if String.contains?(url, "/im/v1/images") do
        {:ok, %{"code" => 0, "data" => %{"image_key" => "img_sync"}}}
      else
        {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    config = feishu_config(false)

    pid =
      start_supervised!(
        {Feishu,
         instance_id: @instance_id,
         config: config,
         channel_config: Config.channel_instance(config, @instance_id),
         http_post_fun: http_post_fun,
         http_post_multipart_fun: http_post_multipart_fun,
         http_get_fun: fn _url, _headers -> {:error, :unexpected} end}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    assert {:ok, %{sent: true, channel: @instance_id, chat_id: "ou_sync"}} =
             Message.execute(
               %{"content" => "sync hello", "channel" => @instance_id, "chat_id" => "ou_sync"},
               %{}
             )

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post, url2, body2, _headers2}
    assert url2 =~ "/im/v1/messages"
    assert body2["receive_id"] == "ou_sync"
  end

  test "message tool uploads local image path for Feishu" do
    parent = self()

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_img"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_post_multipart_fun = fn url, body, headers ->
      send(parent, {:http_post_multipart, url, body, headers})

      if String.contains?(url, "/im/v1/images") do
        {:ok, %{"code" => 0, "data" => %{"image_key" => "img_sync"}}}
      else
        {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    config = feishu_config(false)

    pid =
      start_supervised!(
        {Feishu,
         instance_id: @instance_id,
         config: config,
         channel_config: Config.channel_instance(config, @instance_id),
         http_post_fun: http_post_fun,
         http_post_multipart_fun: http_post_multipart_fun,
         http_get_fun: fn _url, _headers -> {:error, :unexpected} end}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    path =
      Path.join(System.tmp_dir!(), "message_tool_image_#{System.unique_integer([:positive])}.png")

    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{sent: true, channel: @instance_id, chat_id: "ou_sync_img"}} =
             Message.execute(
               %{
                 "channel" => @instance_id,
                 "chat_id" => "ou_sync_img",
                 "local_image_path" => path
               },
               %{config: config}
             )

    assert_receive {:http_post, auth_url, _auth_body, _auth_headers}
    assert auth_url =~ "/auth/v3/tenant_access_token/internal"

    assert_receive {:http_post_multipart, upload_url, multipart_body, _headers2}
    assert upload_url =~ "/im/v1/images"
    assert Keyword.get(multipart_body, :image_type) == "message"

    posts = collect_http_posts([])

    {url2, body2} =
      Enum.find(posts, fn {url, body} ->
        url =~ "/im/v1/messages" and body["msg_type"] == "image"
      end)

    assert url2 =~ "/im/v1/messages"
    assert body2["receive_id"] == "ou_sync_img"
    assert body2["msg_type"] == "image"
    assert Jason.decode!(body2["content"]) == %{"image_key" => "img_sync"}
  end

  test "message tool sends native text before local image for Feishu companion sends" do
    parent = self()

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_combo"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_post_multipart_fun = fn url, body, headers ->
      send(parent, {:http_post_multipart, url, body, headers})

      if String.contains?(url, "/im/v1/images") do
        {:ok, %{"code" => 0, "data" => %{"image_key" => "img_combo"}}}
      else
        {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    config = feishu_config(false)

    pid =
      start_supervised!(
        {Feishu,
         instance_id: @instance_id,
         config: config,
         channel_config: Config.channel_instance(config, @instance_id),
         http_post_fun: http_post_fun,
         http_post_multipart_fun: http_post_multipart_fun,
         http_get_fun: fn _url, _headers -> {:error, :unexpected} end}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    path =
      Path.join(System.tmp_dir!(), "message_tool_combo_#{System.unique_integer([:positive])}.png")

    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{sent: true, channel: @instance_id, chat_id: "ou_combo"}} =
             Message.execute(
               %{
                 "channel" => @instance_id,
                 "chat_id" => "ou_combo",
                 "content" => "海报已生成，见下图。",
                 "local_image_path" => path
               },
               %{config: config}
             )

    assert_receive {:http_post, url1, _body1, _headers1}
    assert url1 =~ "/auth/v3/tenant_access_token/internal"

    posts = collect_http_posts([])

    {url2, body2} =
      Enum.find(posts, fn {url, body} ->
        url =~ "/im/v1/messages" and body["msg_type"] == "interactive"
      end)

    assert url2 =~ "/im/v1/messages"
    assert body2["receive_id"] == "ou_combo"
    assert body2["msg_type"] == "interactive"
    assert Jason.decode!(body2["content"])["elements"] != []

    assert_receive {:http_post_multipart, upload_url, multipart_body, _headers3}
    assert upload_url =~ "/im/v1/images"
    assert Keyword.get(multipart_body, :image_type) == "message"
  end

  test "message tool resolves workspace-relative attachment paths from ctx workspace" do
    workspace =
      Path.join(System.tmp_dir!(), "message_tool_workspace_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    path = Path.join(workspace, "relative-image.png")
    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, outbound} =
             Message.from_tool_args(
               %{
                 "channel" => @instance_id,
                 "chat_id" => "ou_workspace",
                 "attachment_path" => "relative-image.png",
                 "attachment_kind" => "image"
               },
               %{workspace: workspace, cwd: "/tmp/nowhere"}
             )

    assert [attachment] = outbound.attachments
    assert attachment.local_path == path
  end

  defp collect_http_posts(acc) do
    receive do
      {:http_post, url, body, _headers} ->
        collect_http_posts([{url, body} | acc])
    after
      400 -> Enum.reverse(acc)
    end
  end

  defp feishu_config(enabled) do
    channel_config = %{
      "type" => "feishu",
      "enabled" => enabled,
      "app_id" => "cli_test",
      "app_secret" => "sec_test"
    }

    %Config{Config.default() | channel: %{@instance_id => channel_config}}
  end
end
