defmodule Nex.Agent.Channel.DiscordTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{App.Bus, Runtime.Config}
  alias Nex.Agent.Channel.Discord
  alias Nex.Agent.Channel.Discord.StreamConverter
  alias Nex.Agent.Interface.Outbound.Action, as: OutboundAction
  alias Nex.Agent.Interface.Outbound.Approval, as: OutboundApproval
  alias Nex.Agent.Sandbox.Approval.Request

  @instance_id "discord_test"

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    if Process.whereis(Nex.Agent.ChannelRegistry) == nil do
      start_supervised!(Nex.Agent.Interface.Channel.Registry)
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

    http_delete_fun = fn url, headers ->
      send(parent, {:http_delete, url, headers})
      :ok
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
         http_patch_fun: http_patch_fun,
         http_delete_fun: http_delete_fun}
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
    assert %Nex.Agent.Interface.Media.Ref{} = ref
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

  test "approval outbound renders Discord components v2 buttons", %{pid: pid} do
    request =
      Request.new(%{
        id: "approval_component_test",
        kind: :command,
        operation: :execute,
        subject: "git status",
        description: "Allow shell command: read command using git",
        grant_key: "command:execute:exact:test",
        grant_options: [
          %{"level" => "exact", "grant_key" => "command:execute:exact:test"},
          %{"level" => "similar", "grant_key" => "command:execute:family:git:git-read"}
        ],
        workspace: File.cwd!(),
        session_key: "#{@instance_id}:123",
        channel: @instance_id,
        chat_id: "123"
      })

    send(
      pid,
      {:bus_message, {:channel_outbound, @instance_id},
       %{
         chat_id: "123",
         content: """
         Approval required: #{request.description}

         Use `/approve`, `/approve session`, `/approve similar`, `/approve always`, `/deny`, or `/deny all`.
         """,
         metadata: OutboundApproval.metadata(request)
       }}
    )

    assert_receive {:http_post, url, %{"flags" => 32_768, "components" => components}, _headers}
    assert url =~ "/channels/123/messages"

    assert [%{"type" => 10, "content" => content}, %{"type" => 1, "components" => buttons}] =
             components

    assert content == "⚙️ Bash - git status _(Waiting approval)_"
    refute content =~ "/approve"

    labels = Enum.map(buttons, & &1["label"])
    assert "Approve once" in labels
    assert "Allow command" in labels
    assert "Allow similar" in labels
    assert "Always allow" in labels
    assert "Decline" in labels

    assert Enum.any?(buttons, fn button ->
             button["custom_id"] == "nex.approval:approval_component_test:approve_session"
           end)
  end

  test "approval outbound renders risk hint when present", %{pid: pid} do
    request =
      Request.new(%{
        id: "approval_risk_hint_test",
        kind: :command,
        operation: :execute,
        subject: "base64 -d payload.txt | sh",
        description: "Allow shell command: encoded shell command using base64",
        grant_key: "command:execute:exact:risk",
        metadata: %{
          "risk_class" => "encoded_shell",
          "risk_hint" => "Decoded content is piped into a shell."
        },
        workspace: File.cwd!(),
        session_key: "#{@instance_id}:123",
        channel: @instance_id,
        chat_id: "123"
      })

    send(
      pid,
      {:bus_message, {:channel_outbound, @instance_id},
       %{
         chat_id: "123",
         content: "Approval required: #{request.description}",
         metadata: OutboundApproval.metadata(request)
       }}
    )

    assert_receive {:http_post, _url, %{"flags" => 32_768, "components" => components}, _headers}

    assert [
             %{
               "type" => 10,
               "content" => "⚙️ Bash - base64 -d payload.txt | sh _(Waiting approval)_"
             },
             %{"type" => 10, "content" => "_Risk: Decoded content is piped into a shell._"},
             %{"type" => 1, "components" => buttons}
           ] = components

    refute Enum.any?(buttons, &(&1["label"] == "Allow similar"))
  end

  test "generic command action outbound renders a status row without buttons", %{pid: pid} do
    request =
      Request.new(%{
        id: "action_allowed_test",
        kind: :command,
        operation: :execute,
        subject: "ls ~/Desktop/",
        description: "Allow shell command: read command using ls",
        grant_key: "command:execute:exact:allowed",
        workspace: File.cwd!(),
        session_key: "#{@instance_id}:123",
        channel: @instance_id,
        chat_id: "123"
      })

    payload = OutboundAction.command_payload(request, :allowed)

    send(
      pid,
      {:bus_message, {:channel_outbound, @instance_id}, payload}
    )

    assert_receive {:http_post, url, %{"flags" => 32_768, "components" => components}, _headers}
    assert url =~ "/channels/123/messages"
    assert [%{"type" => 10, "content" => content}] = components
    assert content == "⚙️ Bash - ls ~/Desktop/ _(Allowed)_"
  end

  test "approval component click resolves exact pending request and updates action row", %{
    pid: pid
  } do
    unless Process.whereis(Nex.Agent.Sandbox.Approval) do
      start_supervised!({Nex.Agent.Sandbox.Approval, name: Nex.Agent.Sandbox.Approval})
    end

    ws_pid = self()

    :sys.replace_state(pid, fn state ->
      %{state | ws_pid: ws_pid}
    end)

    request =
      Request.new(%{
        id: "approval_component_test",
        kind: :command,
        operation: :execute,
        subject: "git status",
        description: "Allow shell command: read command using git",
        grant_key: "command:execute:exact:test",
        workspace: File.cwd!(),
        session_key: "#{@instance_id}:123",
        channel: @instance_id,
        chat_id: "123"
      })

    task = Task.async(fn -> Nex.Agent.Sandbox.Approval.request(request, publish?: false) end)

    assert eventually(fn ->
             Nex.Agent.Sandbox.Approval.pending?(File.cwd!(), "#{@instance_id}:123")
           end)

    send(
      pid,
      {:discord_ws_message, ws_pid,
       Jason.encode!(%{
         "op" => 0,
         "t" => "INTERACTION_CREATE",
         "s" => 4,
         "d" => %{
           "id" => "interaction-1",
           "application_id" => "app-1",
           "token" => "interaction-token",
           "type" => 3,
           "channel_id" => "123",
           "guild_id" => "guild-1",
           "member" => %{"user" => %{"id" => "user-1", "username" => "alice"}},
           "data" => %{
             "component_type" => 2,
             "custom_id" => "nex.approval:approval_component_test:approve_session"
           },
           "message" => %{
             "id" => "approval-msg-1",
             "components" => [
               %{
                 "type" => 10,
                 "content" => "⚙️ Bash - git status _(Waiting approval)_"
               },
               %{
                 "type" => 1,
                 "components" => [
                   %{
                     "type" => 2,
                     "custom_id" => "nex.approval:approval_component_test:approve_session",
                     "label" => "Allow command",
                     "style" => 1
                   }
                 ]
               }
             ]
           }
         }
       })}
    )

    assert_receive {:http_post, url, %{"type" => 6}, _headers}
    assert url =~ "/interactions/interaction-1/interaction-token/callback"

    assert_receive {:http_patch, patch_url, %{"flags" => 32_768, "components" => components},
                    _headers}

    assert patch_url =~ "/channels/123/messages/approval-msg-1"
    assert [%{"type" => 10, "content" => status_text}] = components
    assert status_text == "⚙️ Bash - git status _(Allowed for session)_"
    assert Task.await(task) == {:ok, :approved}
    refute_received {:bus_message, :inbound, _inbound}
  end

  test "stream approval row is a separate action message and preserves model stream", %{pid: _pid} do
    assert {:ok, converter} = StreamConverter.start(@instance_id, "123", %{})
    assert_receive {:http_post, _url, %{"content" => "🤔 Thinking..."}, _headers}
    placeholder_message_id = converter.current_message_id

    request =
      Request.new(%{
        id: "approval_stream_test",
        kind: :command,
        operation: :execute,
        subject: "ls -la ~/Desktop/",
        description: "Allow shell command: read command using ls",
        grant_key: "command:execute:exact:desktop",
        workspace: File.cwd!(),
        session_key: "#{@instance_id}:123",
        channel: @instance_id,
        chat_id: "123"
      })

    payload = OutboundApproval.payload(request, "Approval required")
    assert {:ok, converter} = StreamConverter.approval_request(converter, payload)

    assert_receive {:http_delete, delete_url, _headers}
    assert delete_url =~ "/channels/123/messages/#{placeholder_message_id}"

    assert_receive {:http_post, post_url, %{"flags" => 32_768, "components" => components},
                    _headers}

    assert post_url =~ "/channels/123/messages"

    assert [%{"type" => 10, "content" => content}, %{"type" => 1, "components" => buttons}] =
             components

    assert content == "⚙️ Bash - ls -la ~/Desktop/ _(Waiting approval)_"
    assert buttons != []
    assert converter.current_message_id == nil
    refute converter.placeholder
    assert converter.waiting_for_approval

    assert {:ok, converter} = StreamConverter.push_text(converter, "触发了。")
    assert_receive {:http_post, post_url, %{"content" => "触发了。"}, _headers}
    assert post_url =~ "/channels/123/messages"
    assert converter.active_text == "触发了。"
    refute converter.waiting_for_approval
  end

  test "stream approval seals existing model content before action messages", %{pid: _pid} do
    assert {:ok, converter} = StreamConverter.start(@instance_id, "123", %{})
    assert_receive {:http_post, _url, %{"content" => "🤔 Thinking..."}, _headers}

    assert {:ok, converter} = StreamConverter.push_text(converter, "我先解释一下。")
    assert_receive {:http_patch, first_url, %{"content" => "我先解释一下。"}, _headers}
    assert first_url =~ "/channels/123/messages/#{converter.current_message_id}"
    first_message_id = converter.current_message_id

    assert {:ok, converter} = StreamConverter.refresh_working_status(converter)
    assert_receive {:http_patch, status_url, %{"content" => status_content}, _headers}
    assert status_url =~ "/channels/123/messages/#{first_message_id}"
    assert status_content =~ "_Still working..."

    request =
      Request.new(%{
        id: "approval_after_text_test",
        kind: :command,
        operation: :execute,
        subject: "ls ~/Desktop/",
        description: "Allow shell command: read command using ls",
        grant_key: "command:execute:exact:desktop-after-text",
        workspace: File.cwd!(),
        session_key: "#{@instance_id}:123",
        channel: @instance_id,
        chat_id: "123"
      })

    assert {:ok, converter} =
             StreamConverter.approval_request(
               converter,
               OutboundApproval.payload(request, "Approval required")
             )

    assert_receive {:http_patch, clear_url, %{"content" => "我先解释一下。"}, _headers}
    assert clear_url =~ "/channels/123/messages/#{first_message_id}"

    assert_receive {:http_post, _url, %{"flags" => 32_768, "components" => components}, _headers}

    assert [%{"content" => "⚙️ Bash - ls ~/Desktop/ _(Waiting approval)_"}, _] = components
    assert converter.current_message_id == nil
    assert converter.active_text == ""
    refute converter.placeholder
    assert converter.waiting_for_approval

    assert {:ok, converter} = StreamConverter.push_text(converter, "命令通过后继续。")
    assert_receive {:http_post, post_url, %{"content" => "命令通过后继续。"}, _headers}
    assert post_url =~ "/channels/123/messages"
    refute converter.waiting_for_approval

    refute_received {:http_delete, _url, _headers}
  end

  test "stream approval requests create independent action messages", %{pid: _pid} do
    assert {:ok, converter} = StreamConverter.start(@instance_id, "123", %{})
    assert_receive {:http_post, _url, %{"content" => "🤔 Thinking..."}, _headers}
    placeholder_message_id = converter.current_message_id

    request1 =
      Request.new(%{
        id: "approval_stream_first",
        kind: :command,
        operation: :execute,
        subject: "ls ~/Desktop/ | head -5",
        description: "Allow shell command: read command using ls",
        grant_key: "command:execute:exact:desktop-first",
        workspace: File.cwd!(),
        session_key: "#{@instance_id}:123",
        channel: @instance_id,
        chat_id: "123"
      })

    request2 =
      Request.new(%{
        id: "approval_stream_second",
        kind: :command,
        operation: :execute,
        subject: "ls ~/Desktop/krisxin_kb/",
        description: "Allow shell command: read command using ls",
        grant_key: "command:execute:exact:desktop-second",
        workspace: File.cwd!(),
        session_key: "#{@instance_id}:123",
        channel: @instance_id,
        chat_id: "123"
      })

    assert {:ok, converter} =
             StreamConverter.approval_request(
               converter,
               OutboundApproval.payload(request1, "Approval required")
             )

    assert {:ok, converter} =
             StreamConverter.approval_request(
               converter,
               OutboundApproval.payload(request2, "Approval required")
             )

    assert_receive {:http_delete, delete_url, _headers}
    assert delete_url =~ "/channels/123/messages/#{placeholder_message_id}"

    assert_receive {:http_post, _url1, %{"flags" => 32_768, "components" => components1},
                    _headers1}

    assert_receive {:http_post, _url2, %{"flags" => 32_768, "components" => components2},
                    _headers2}

    assert [%{"content" => content1}, %{"components" => buttons1}] = components1
    assert [%{"content" => content2}, %{"components" => buttons2}] = components2

    assert content1 == "⚙️ Bash - ls ~/Desktop/ | head -5 _(Waiting approval)_"
    assert content2 == "⚙️ Bash - ls ~/Desktop/krisxin_kb/ _(Waiting approval)_"

    assert Enum.any?(buttons1, fn button ->
             button["custom_id"] == "nex.approval:approval_stream_first:approve_once"
           end)

    assert Enum.any?(buttons2, fn button ->
             button["custom_id"] == "nex.approval:approval_stream_second:approve_once"
           end)

    assert converter.current_message_id == nil
    refute converter.placeholder
    assert converter.waiting_for_approval

    refute_received {:http_patch, _url, %{"flags" => 32_768, "components" => _components},
                     _headers}
  end

  test "stream approval retries transient component delivery before text fallback", %{pid: pid} do
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | http_post_fun: fn
            url, %{"components" => _components} = body, headers ->
              attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)

              if attempt == 1 do
                send(parent, {:http_post_failed, url, body, headers})
                {:error, {:http_error, 503, %{"message" => "temporary overload"}}}
              else
                send(parent, {:http_post, url, body, headers})
                {:ok, %{"id" => "approval-retry-success", "flags" => 32_768}}
              end

            url, body, headers ->
              send(parent, {:http_post, url, body, headers})
              {:ok, %{"id" => "msg_" <> Integer.to_string(System.unique_integer([:positive]))}}
          end
      }
    end)

    assert {:ok, converter} = StreamConverter.start(@instance_id, "123", %{})
    assert_receive {:http_post, _url, %{"content" => "🤔 Thinking..."}, _headers}

    request =
      Request.new(%{
        id: "approval_retry_test",
        kind: :command,
        operation: :execute,
        subject: "ls ~/Desktop/krisxin_kb/",
        description: "Allow shell command: read command using ls",
        grant_key: "command:execute:exact:desktop-retry",
        workspace: File.cwd!(),
        session_key: "#{@instance_id}:123",
        channel: @instance_id,
        chat_id: "123"
      })

    assert {:ok, converter} =
             StreamConverter.approval_request(
               converter,
               OutboundApproval.payload(request, "Approval required")
             )

    assert_receive {:http_delete, _url, _headers}

    assert_receive {:http_post_failed, _url, %{"flags" => 32_768, "components" => _components},
                    _headers}

    assert_receive {:http_post, _url, %{"flags" => 32_768, "components" => components}, _headers}

    assert [%{"content" => "⚙️ Bash - ls ~/Desktop/krisxin_kb/ _(Waiting approval)_"}, _] =
             components

    assert Agent.get(attempts, & &1) == 2
    assert converter.waiting_for_approval

    refute_received {:http_post, _url, %{"content" => _fallback_content, "embeds" => []},
                     _headers}
  end

  test "stream approval falls back to text commands when components delivery fails", %{pid: pid} do
    parent = self()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | http_post_fun: fn
            url, %{"components" => _components} = body, headers ->
              send(parent, {:http_post_failed, url, body, headers})
              {:error, {:discord, 400, "components v2 rejected"}}

            url, body, headers ->
              send(parent, {:http_post, url, body, headers})
              {:ok, %{"id" => "msg_" <> Integer.to_string(System.unique_integer([:positive]))}}
          end
      }
    end)

    assert {:ok, converter} = StreamConverter.start(@instance_id, "123", %{})
    assert_receive {:http_post, _url, %{"content" => "🤔 Thinking..."}, _headers}

    request =
      Request.new(%{
        id: "approval_fallback_test",
        kind: :command,
        operation: :execute,
        subject: "ls ~/Desktop/",
        description: "Allow shell command: read command using ls",
        grant_key: "command:execute:exact:desktop-fallback",
        workspace: File.cwd!(),
        session_key: "#{@instance_id}:123",
        channel: @instance_id,
        chat_id: "123"
      })

    content = """
    Approval required: #{request.description}

    Use `/approve #{request.id}`, `/approve #{request.id} session`, `/approve #{request.id} similar`, `/approve #{request.id} always`, or `/deny #{request.id}`.
    """

    assert {:ok, converter} =
             StreamConverter.approval_request(
               converter,
               OutboundApproval.payload(request, content)
             )

    assert_receive {:http_delete, _url, _headers}

    assert_receive {:http_post_failed, _url, %{"flags" => 32_768, "components" => _components},
                    _headers}

    assert_receive {:http_post, _url, %{"content" => fallback_content, "embeds" => []}, _headers}
    assert fallback_content =~ "Approval required: Allow shell command: read command using ls"
    assert fallback_content =~ "/approve approval_fallback_test"
    assert fallback_content =~ "/deny approval_fallback_test"
    assert converter.current_message_id == nil
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

  test "delete_message deletes existing Discord message", %{pid: _pid} do
    assert :ok = Discord.delete_message(@instance_id, "123", "msg_1")

    assert_receive {:http_delete, url, headers}
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

    assert %Nex.Agent.Conversation.Command.Invocation{name: "status", source: :native} =
             inbound.command
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

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
