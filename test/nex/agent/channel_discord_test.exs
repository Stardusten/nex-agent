defmodule Nex.Agent.Channel.DiscordTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Config}
  alias Nex.Agent.Channel.Discord
  alias Nex.Agent.Channel.Discord.StreamConverter

  @instance_id "discord_test"

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    if Process.whereis(Nex.Agent.ChannelRegistry) == nil do
      start_supervised!(Nex.Agent.Channel.Registry)
    end

    Bus.subscribe(:inbound)

    parent = self()

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      {:ok, %{"id" => "msg_" <> Integer.to_string(System.unique_integer([:positive]))}}
    end

    http_patch_fun = fn url, body, headers ->
      send(parent, {:http_patch, url, body, headers})
      {:ok, %{"id" => "patched"}}
    end

    channel_config = %{"type" => "discord", "enabled" => false, "token" => "discord-token"}
    config = %Config{Config.default() | channel: %{@instance_id => channel_config}}

    pid =
      start_supervised!(
        {Discord,
         instance_id: @instance_id,
         config: config,
         channel_config: channel_config,
         http_post_fun: http_post_fun,
         http_patch_fun: http_patch_fun}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, token: "discord-token"}
    end)

    {:ok, pid: pid}
  end

  test "thread message publishes Discord attachments as media refs without gateway download", %{
    pid: pid
  } do
    ws_pid = self()

    :sys.replace_state(pid, fn state ->
      %{state | ws_pid: ws_pid}
    end)

    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "READY",
         "s" => 1,
         "d" => %{
           "user" => %{"id" => "bot-1", "username" => "nex-bot"},
           "session_id" => "session-1",
           "resume_gateway_url" => "wss://gateway.discord.gg"
         }
       })}
    )

    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "GUILD_CREATE",
         "s" => 2,
         "d" => %{
           "id" => "guild-1",
           "threads" => [
             %{"id" => "thread-1", "type" => 11, "guild_id" => "guild-1", "parent_id" => "123"}
           ]
         }
       })}
    )

    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "MESSAGE_CREATE",
         "s" => 3,
         "d" => %{
           "id" => "msg-file-1",
           "channel_id" => "thread-1",
           "guild_id" => "guild-1",
           "content" => "你能看到这个文件内容吗",
           "author" => %{"id" => "user-1", "username" => "alice"},
           "mentions" => [],
           "attachments" => [
             %{
               "id" => "att-1",
               "filename" => "note.txt",
               "content_type" => "text/plain",
               "size" => 23,
               "url" => "https://cdn.discordapp.com/attachments/123/note.txt",
               "proxy_url" => "https://media.discordapp.net/attachments/123/note.txt"
             }
           ]
         }
       })}
    )

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.chat_id == "thread-1"
    assert inbound.text == "你能看到这个文件内容吗"
    assert inbound.attachments == []
    assert [ref] = inbound.media_refs
    assert %Nex.Agent.Media.Ref{} = ref
    assert ref.kind == :file
    assert ref.mime_type == "text/plain"
    assert ref.filename == "note.txt"
    assert ref.message_id == "msg-file-1"
    assert ref.platform_ref["url"] == "https://cdn.discordapp.com/attachments/123/note.txt"
  end

  test "outbound newmsg text creates multiple Discord messages", %{pid: pid} do
    send(
      pid,
      {:bus_message, {:channel_outbound, @instance_id},
       %{chat_id: "123", content: "first\n<newmsg/>\nsecond", metadata: %{}}}
    )

    assert_receive {:http_post, url1, %{"content" => "first"}, headers1}
    assert url1 =~ "/channels/123/messages"
    assert {"authorization", "Bot discord-token"} in headers1

    assert_receive {:http_post, url2, %{"content" => "second"}, _headers2}
    assert url2 =~ "/channels/123/messages"
  end

  test "outbound threshold split keeps fenced code block intact", %{pid: pid} do
    prefix = String.duplicate("x", 1990)
    code_block = "```text\nhello\n```"

    send(
      pid,
      {:bus_message, {:channel_outbound, @instance_id},
       %{chat_id: "123", content: prefix <> "\n\n" <> code_block, metadata: %{}}}
    )

    assert_receive {:http_post, _url1, %{"content" => ^prefix}, _headers1}
    assert_receive {:http_post, _url2, %{"content" => ^code_block}, _headers2}
  end

  test "stream converter treats inline newmsg as boundary", %{pid: _pid} do
    assert {:ok, converter} = StreamConverter.start(@instance_id, "123", %{})
    assert_receive {:http_post, _url, %{"content" => "🤔 Thinking..."}, _headers}

    assert {:ok, converter} = StreamConverter.push_text(converter, "我搜一下。<new")
    assert_receive {:http_patch, _url, %{"content" => "我搜一下。"}, _headers}

    assert {:ok, converter} = StreamConverter.push_text(converter, "msg/>second")
    assert {:ok, converter} = StreamConverter.finish(converter)

    assert converter.completed
    assert_receive {:http_post, _url, %{"content" => "second"}, _headers}
    refute converter.active_text =~ "<newmsg/>"
  end

  test "stream converter splits newmsg wherever it appears", %{pid: _pid} do
    assert {:ok, converter} = StreamConverter.start(@instance_id, "123", %{})
    assert_receive {:http_post, _url, %{"content" => "🤔 Thinking..."}, _headers}

    assert {:ok, converter} = StreamConverter.push_text(converter, "Use <newmsg/> token")
    assert {:ok, converter} = StreamConverter.finish(converter)

    assert converter.completed
    assert_receive {:http_patch, _url, %{"content" => "Use"}, _headers}
    assert_receive {:http_post, _url, %{"content" => "token"}, _headers}
  end

  test "stream converter threshold split rotates before fenced code block", %{pid: _pid} do
    prefix = String.duplicate("x", 1990)
    code_block = "```text\nhello\n```"

    assert {:ok, converter} = StreamConverter.start(@instance_id, "123", %{})
    assert_receive {:http_post, _url, %{"content" => "🤔 Thinking..."}, _headers}

    assert {:ok, converter} = StreamConverter.push_text(converter, prefix)
    assert_receive {:http_patch, _url, %{"content" => ^prefix}, _headers}

    assert {:ok, converter} = StreamConverter.push_text(converter, "\n\n" <> code_block)
    assert {:ok, converter} = StreamConverter.finish(converter)

    assert converter.completed
    assert_receive {:http_patch, _url, %{"content" => ^prefix}, _headers}
    assert_receive {:http_post, _url, %{"content" => ^code_block}, _headers}
  end

  test "stream converter shows temporary working status and clears it on new text", %{pid: _pid} do
    assert {:ok, converter} = StreamConverter.start(@instance_id, "123", %{})
    assert_receive {:http_post, _url, %{"content" => "🤔 Thinking..."}, _headers}

    assert {:ok, converter} = StreamConverter.push_text(converter, "hello")
    assert_receive {:http_patch, _url, %{"content" => "hello"}, _headers}

    assert {:ok, converter} = StreamConverter.refresh_working_status(converter)
    assert_receive {:http_patch, _url, %{"content" => status_content}, _headers}
    assert status_content =~ "hello\n\n_Still working..."

    assert {:ok, converter} = StreamConverter.push_text(converter, " world")
    assert_receive {:http_patch, _url, %{"content" => "hello world"}, _headers}

    assert {:ok, _converter} = StreamConverter.finish(converter)
  end

  test "stream converter clears temporary working status on finish", %{pid: _pid} do
    assert {:ok, converter} = StreamConverter.start(@instance_id, "123", %{})
    assert_receive {:http_post, _url, %{"content" => "🤔 Thinking..."}, _headers}

    assert {:ok, converter} = StreamConverter.push_text(converter, "hello")
    assert_receive {:http_patch, _url, %{"content" => "hello"}, _headers}

    assert {:ok, converter} = StreamConverter.refresh_working_status(converter)
    assert_receive {:http_patch, _url, %{"content" => status_content}, _headers}
    assert status_content =~ "Still working"

    assert {:ok, _converter} = StreamConverter.finish(converter)
    assert_receive {:http_patch, _url, %{"content" => "hello"}, _headers}
  end

  test "deliver_message returns created message_id", %{pid: _pid} do
    assert {:ok, "msg_" <> _rest} = Discord.deliver_message(@instance_id, "123", "hello", %{})

    assert_receive {:http_post, url, %{"content" => "hello"}, _headers}
    assert url =~ "/channels/123/messages"
  end

  test "update_message patches existing Discord message", %{pid: _pid} do
    assert :ok = Discord.update_message(@instance_id, "123", "msg_1", "hello updated", %{})

    assert_receive {:http_patch, url, %{"content" => "hello updated"}, headers}
    assert url =~ "/channels/123/messages/msg_1"
    assert {"authorization", "Bot discord-token"} in headers
  end

  test "outbound tables are rendered as ascii by default", %{pid: pid} do
    table = """
    | name | score |
    | --- | --- |
    | alice | 10 |
    """

    send(
      pid,
      {:bus_message, {:channel_outbound, @instance_id},
       %{chat_id: "123", content: table, metadata: %{}}}
    )

    assert_receive {:http_post, _url, %{"content" => content, "embeds" => []}, _headers}
    assert content =~ "+-------+-------+"
    assert content =~ "| name  | score |"
    assert content =~ "| alice | 10    |"
  end

  test "outbound tables can be rendered as Discord embed fields", %{pid: pid} do
    :sys.replace_state(pid, fn state -> %{state | show_table_as: :embed} end)

    table = """
    | name | score |
    | --- | --- |
    | alice | 10 |
    """

    send(
      pid,
      {:bus_message, {:channel_outbound, @instance_id},
       %{chat_id: "123", content: table, metadata: %{}}}
    )

    assert_receive {:http_post, _url,
                    %{"content" => "Table: name / score", "embeds" => [%{"fields" => fields}]},
                    _headers}

    assert %{"name" => "name", "value" => "alice", "inline" => true} in fields
    assert %{"name" => "score", "value" => "10", "inline" => true} in fields
  end

  test "outbound tables can be rendered raw", %{pid: pid} do
    :sys.replace_state(pid, fn state -> %{state | show_table_as: :raw} end)

    table = """
    | name | score |
    | --- | --- |
    | alice | 10 |
    """

    send(
      pid,
      {:bus_message, {:channel_outbound, @instance_id},
       %{chat_id: "123", content: table, metadata: %{}}}
    )

    assert_receive {:http_post, _url, %{"content" => content, "embeds" => []}, _headers}
    assert content == "| name | score |\n| --- | --- |\n| alice | 10 |"
  end

  test "mentioned inbound message auto-creates thread and publishes to inbound bus", %{pid: pid} do
    ws_pid = self()

    :sys.replace_state(pid, fn state ->
      %{state | ws_pid: ws_pid}
    end)

    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "READY",
         "s" => 1,
         "d" => %{
           "user" => %{"id" => "bot-1", "username" => "nex-bot"},
           "session_id" => "session-1",
           "resume_gateway_url" => "wss://gateway.discord.gg"
         }
       })}
    )

    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "MESSAGE_CREATE",
         "s" => 2,
         "d" => %{
           "id" => "msg-1",
           "channel_id" => "123",
           "guild_id" => "guild-1",
           "content" => "<@bot-1> hello discord",
           "author" => %{"id" => "user-1", "username" => "alice"},
           "mentions" => [%{"id" => "bot-1"}]
         }
       })}
    )

    # Thread creation POST
    assert_receive {:http_post, thread_url, _body, _headers}
    assert thread_url =~ "/threads"

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.channel == @instance_id
    assert inbound.metadata["channel_type"] == "discord"
    # chat_id is the auto-created thread ID, not the original channel
    refute inbound.chat_id == "123"
    assert inbound.sender_id == "user-1"
    assert inbound.text == "hello discord"
    assert inbound.metadata["message_id"] == "msg-1"
    assert inbound.metadata["parent_chat_id"] == "123"
  end

  test "message inside a thread responds without @mention", %{pid: pid} do
    ws_pid = self()

    :sys.replace_state(pid, fn state ->
      %{state | ws_pid: ws_pid}
    end)

    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "READY",
         "s" => 1,
         "d" => %{
           "user" => %{"id" => "bot-1", "username" => "nex-bot"},
           "session_id" => "session-1",
           "resume_gateway_url" => "wss://gateway.discord.gg"
         }
       })}
    )

    # GUILD_CREATE caches thread-1 as a known thread (mirrors discord.py's guild._threads)
    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "GUILD_CREATE",
         "s" => 2,
         "d" => %{
           "id" => "guild-1",
           "threads" => [
             %{"id" => "thread-1", "type" => 11, "guild_id" => "guild-1", "parent_id" => "123"}
           ]
         }
       })}
    )

    # Message in the cached thread — no @mention required
    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "MESSAGE_CREATE",
         "s" => 3,
         "d" => %{
           "id" => "msg-2",
           "channel_id" => "thread-1",
           "guild_id" => "guild-1",
           "content" => "follow up question",
           "author" => %{"id" => "user-1", "username" => "alice"},
           "mentions" => []
         }
       })}
    )

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.channel == @instance_id
    assert inbound.metadata["channel_type"] == "discord"
    assert inbound.chat_id == "thread-1"
    assert inbound.metadata["parent_chat_id"] == "123"
    assert inbound.text == "follow up question"
  end

  test "message inside allowed thread uses parent channel for allow_from check", %{pid: pid} do
    ws_pid = self()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | ws_pid: ws_pid,
          allow_from: ["123"],
          known_threads: %{"thread-allowed" => %{parent_id: "123", guild_id: "guild-1"}}
      }
    end)

    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "READY",
         "s" => 1,
         "d" => %{
           "user" => %{"id" => "bot-1", "username" => "nex-bot"},
           "session_id" => "session-1",
           "resume_gateway_url" => "wss://gateway.discord.gg"
         }
       })}
    )

    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "MESSAGE_CREATE",
         "s" => 2,
         "d" => %{
           "id" => "msg-thread-1",
           "channel_id" => "thread-allowed",
           "guild_id" => "guild-1",
           "content" => "allowed follow up",
           "author" => %{"id" => "user-1", "username" => "alice"},
           "mentions" => []
         }
       })}
    )

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.chat_id == "thread-allowed"
    assert inbound.metadata["parent_chat_id"] == "123"
    assert inbound.text == "allowed follow up"
  end

  test "native slash interaction is acknowledged and published as inbound command", %{pid: pid} do
    ws_pid = self()

    :sys.replace_state(pid, fn state ->
      %{state | ws_pid: ws_pid, allow_from: ["123"], bot_user_id: "bot-1"}
    end)

    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "INTERACTION_CREATE",
         "s" => 3,
         "d" => %{
           "id" => "interaction-1",
           "token" => "interaction-token",
           "type" => 2,
           "channel_id" => "123",
           "guild_id" => "guild-1",
           "member" => %{"user" => %{"id" => "user-1", "username" => "alice"}},
           "data" => %{
             "name" => "status",
             "options" => []
           }
         }
       })}
    )

    assert_receive {:http_post, callback_url, %{"type" => 5}, _headers}
    assert callback_url =~ "/interactions/interaction-1/interaction-token/callback"

    assert_receive {:bus_message, :inbound, inbound}
    assert inbound.channel == @instance_id
    assert inbound.metadata["channel_type"] == "discord"
    assert inbound.chat_id == "123"
    assert inbound.text == "/status"
    assert %Nex.Agent.Command.Invocation{name: "status", source: :native} = inbound.command
  end

  test "discord outbound with interaction token edits original interaction response", %{pid: pid} do
    send(
      pid,
      {:bus_message, {:channel_outbound, @instance_id},
       %{
         chat_id: "123",
         content: "Status: idle",
         metadata: %{
           "application_id" => "app-1",
           "interaction_token" => "interaction-token"
         }
       }}
    )

    assert_receive {:http_patch, url, %{"content" => "Status: idle", "embeds" => []}, headers}
    assert url =~ "/webhooks/app-1/interaction-token/messages/@original"
    assert {"authorization", "Bot discord-token"} in headers
  end

  test "normal websocket close keeps discord enabled and schedules reconnect", %{pid: pid} do
    ws_pid = spawn(fn -> Process.sleep(:infinity) end)

    :sys.replace_state(pid, fn state ->
      %{state | ws_pid: ws_pid, ws_ref: Process.monitor(ws_pid), enabled: true}
    end)

    send(pid, {:discord_ws_disconnected, ws_pid, {:remote, 1000, ""}})
    Process.sleep(10)

    state = :sys.get_state(pid)
    assert state.enabled == true
    assert state.ws_pid == nil
  end

  test "authentication failure disables discord instead of reconnecting forever", %{pid: pid} do
    ws_pid = spawn(fn -> Process.sleep(:infinity) end)

    :sys.replace_state(pid, fn state ->
      %{state | ws_pid: ws_pid, ws_ref: Process.monitor(ws_pid), enabled: true}
    end)

    send(pid, {:discord_ws_disconnected, ws_pid, {:remote, 4004, "Authentication failed."}})
    Process.sleep(10)

    state = :sys.get_state(pid)
    assert state.enabled == false
    assert state.ws_pid == nil
  end

  test "discord init strips Bot prefix from configured token" do
    channel_config = %{"type" => "discord", "enabled" => false, "token" => "Bot discord-token"}
    config = %Config{Config.default() | channel: %{@instance_id => channel_config}}

    {:ok, state, {:continue, :connect}} =
      Discord.init(
        instance_id: @instance_id,
        config: config,
        channel_config: channel_config,
        http_post_fun: fn _url, _body, _headers -> {:ok, %{"id" => "msg_1"}} end,
        http_patch_fun: fn _url, _body, _headers -> {:ok, %{"id" => "patched"}} end
      )

    assert state.token == "discord-token"
  end

  test "deliver_message adds Bot prefix once when config token already contains Bot prefix", %{
    pid: pid
  } do
    :sys.replace_state(pid, fn state -> %{state | token: "Bot discord-token", enabled: true} end)

    assert {:ok, "msg_" <> _} = Discord.deliver_message(@instance_id, "123", "hello", %{})
    assert_receive {:http_post, _url, %{"content" => "hello"}, headers}
    assert {"authorization", "Bot discord-token"} in headers
  end
end
