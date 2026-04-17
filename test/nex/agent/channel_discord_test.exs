defmodule Nex.Agent.Channel.DiscordTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Config}
  alias Nex.Agent.Channel.Discord

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
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

    config = %Config{Config.default() | discord: %{"enabled" => false}}

    if Process.whereis(Discord), do: GenServer.stop(Discord)

    pid =
      start_supervised!(
        {Discord,
         config: config,
         http_post_fun: http_post_fun,
         http_patch_fun: http_patch_fun}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, token: "discord-token"}
    end)

    {:ok, pid: pid}
  end

  test "outbound newmsg text creates multiple Discord messages", %{pid: pid} do
    send(
      pid,
      {:bus_message, :discord_outbound,
       %{chat_id: "123", content: "first\n<newmsg/>\nsecond", metadata: %{}}}
    )

    assert_receive {:http_post, url1, %{"content" => "first"}, headers1}
    assert url1 =~ "/channels/123/messages"
    assert {"authorization", "Bot discord-token"} in headers1

    assert_receive {:http_post, url2, %{"content" => "second"}, _headers2}
    assert url2 =~ "/channels/123/messages"
  end

  test "deliver_message returns created message_id", %{pid: _pid} do
    assert {:ok, "msg_" <> _rest} = Discord.deliver_message("123", "hello", %{})

    assert_receive {:http_post, url, %{"content" => "hello"}, _headers}
    assert url =~ "/channels/123/messages"
  end

  test "update_message patches existing Discord message", %{pid: _pid} do
    assert :ok = Discord.update_message("123", "msg_1", "hello updated", %{})

    assert_receive {:http_patch, url, %{"content" => "hello updated"}, headers}
    assert url =~ "/channels/123/messages/msg_1"
    assert {"authorization", "Bot discord-token"} in headers
  end

  test "outbound tables are passed through as-is for Discord (tables: false)", %{pid: pid} do
    table = """
    | name | score |
    | --- | --- |
    | alice | 10 |
    """

    send(pid, {:bus_message, :discord_outbound, %{chat_id: "123", content: table, metadata: %{}}})

    assert_receive {:http_post, _url, %{"content" => content}, _headers}
    # With tables: false, table lines are treated as paragraphs, no code block wrapping
    assert content =~ "| name | score |"
    refute content =~ "```text"
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
    assert inbound.channel == "discord"
    # chat_id is the auto-created thread ID, not the original channel
    refute inbound.chat_id == "123"
    assert inbound.sender_id == "user-1"
    assert inbound.text == "hello discord"
    assert inbound.metadata["message_id"] == "msg-1"
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
           "threads" => [%{"id" => "thread-1", "type" => 11, "guild_id" => "guild-1"}]
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
    assert inbound.channel == "discord"
    assert inbound.chat_id == "thread-1"
    assert inbound.text == "follow up question"
  end
end
