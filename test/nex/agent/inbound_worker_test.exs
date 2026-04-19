defmodule Nex.Agent.InboundWorkerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, InboundWorker, Memory, Runner, Runtime, Session, Skills}
  alias Nex.Agent.Channel.{Discord, Feishu}
  alias Nex.Agent.Inbound.Envelope
  alias Nex.Agent.Media.Attachment
  alias Nex.Agent.Stream.Result

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-inbound-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")
    File.write!(Path.join(workspace, "memory/HISTORY.md"), "# History\n")

    Application.put_env(:nex_agent, :workspace_path, workspace)
    Skills.load()

    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Nex.Agent.Tool.Registry) == nil do
      start_supervised!({Nex.Agent.Tool.Registry, name: Nex.Agent.Tool.Registry})
    end

    if Process.whereis(Nex.Agent.SessionManager) == nil do
      start_supervised!({Nex.Agent.SessionManager, name: Nex.Agent.SessionManager})
    end

    if Process.whereis(Nex.Agent.MemoryUpdater) == nil do
      start_supervised!({Nex.Agent.MemoryUpdater, name: Nex.Agent.MemoryUpdater})
    end

    worker_name = String.to_atom("inbound_worker_test_#{System.unique_integer([:positive])}")
    parent = self()
    config = %Nex.Agent.Config{
      Nex.Agent.Config.default()
      | feishu: %{"enabled" => true, "streaming" => true},
        discord: %{"enabled" => true, "streaming" => true}
    }

    prompt_fun = fn agent, prompt, opts ->
      Process.put(:llm_call_count, 0)

      llm_client = fn _messages, _llm_opts ->
        case Process.get(:llm_call_count, 0) do
          0 ->
            Process.put(:llm_call_count, 1)

            {:ok,
             %{
               content: [%{"nested" => [%{"x" => 1}]}],
               finish_reason: nil,
               tool_calls: [
                 %{
                   id: "call_progress_content",
                   function: %{
                     name: "list_dir",
                     arguments: %{"path" => "."}
                   }
                 }
               ]
             }}

          _ ->
            send(parent, :llm_finished)
            {:ok, %{content: "done", finish_reason: nil, tool_calls: []}}
        end
      end

      runner_opts = [
        llm_stream_client: stream_client_from_response(llm_client),
        workspace: workspace,
        skip_consolidation: true,
        stream_sink: Keyword.get(opts, :stream_sink),
        channel: Keyword.get(opts, :channel),
        chat_id: Keyword.get(opts, :chat_id)
      ]

      case Runner.run(agent.session, prompt, runner_opts) do
        {:ok, result, session} -> {:ok, result, %{agent | session: session}}
        {:error, reason, session} -> {:error, reason, %{agent | session: session}}
      end
    end

    start_supervised!(%{
      id: worker_name,
      start:
        {InboundWorker, :start_link, [[name: worker_name, config: config, agent_prompt_fun: prompt_fun]]}
    })

    Bus.subscribe(:feishu_outbound)
    Bus.subscribe(:discord_outbound)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace, worker_name: worker_name}
  end

  test "slash commands listing is handled without calling the llm", %{worker_name: worker_name} do
    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-commands",
        sender_id: "tester",
        text: "/commands",
        message_type: :text,
        raw: %{},
        metadata: %{},
        media_refs: [],
        attachments: []
      }
    })

    payloads = collect_feishu_payloads([])
    [payload] = Enum.filter(payloads, &is_binary(&1.content))

    assert payload.content =~ "Available slash commands:"
    assert payload.content =~ "/new - reset the current chat session"
    assert payload.content =~ "/stop - stop the current task and clear queued messages"
    assert payload.content =~ "/commands - list supported slash commands for this chat"
    assert payload.content =~ "/status - show current owner run status immediately"
    assert payload.content =~ "/queue <message> - queue a message for the next owner turn"
    assert payload.content =~ "/btw <message> - ask a side question without interrupting the owner run"
    refute_received :llm_finished
  end

  test "unknown slash-prefixed text still goes through the llm path", %{workspace: workspace} do
    parent = self()
    worker_name = String.to_atom("inbound_worker_unknown_slash_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, prompt, _opts ->
      send(parent, {:prompt_received, prompt})
      {:ok, "done", %{agent | workspace: workspace}}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-unknown-slash",
        sender_id: "tester",
        text: "/code keep this literal",
        message_type: :text,
        raw: %{},
        metadata: %{},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:prompt_received, "/code keep this literal"}, 1_000
  end

  test "built-in slash new command bypasses llm execution", %{workspace: workspace} do
    parent = self()
    worker_name = String.to_atom("inbound_worker_new_command_#{System.unique_integer([:positive])}")

    prompt_fun = fn _agent, _prompt, _opts ->
      send(parent, :prompt_called)
      raise "slash command should not call llm"
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-new",
        sender_id: "tester",
        text: "/new",
        message_type: :text,
        raw: %{},
        metadata: %{"workspace" => workspace},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:bus_message, :feishu_outbound, payload}, 1_000
    assert payload.content == "New session started."
    refute_received :prompt_called
  end

  test "feishu outbound only sends final user reply, not progress chatter", %{
    worker_name: worker_name
  } do
    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-1",
        sender_id: "tester",
        text: "hello",
        message_type: :text,
        raw: %{},
        metadata: %{},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive :llm_finished, 1_000

    payloads = collect_feishu_payloads([])

    assert Enum.any?(payloads, &(&1.content == "done"))
    refute Enum.any?(payloads, &(&1.metadata["_progress"] == true))

    refute Enum.any?(payloads, fn payload ->
             is_binary(payload.content) and
               String.contains?(
                 payload.content,
                 "nofunction clause matching in io.chardata_to_string"
               )
           end)
  end

  test "inbound worker forwards attachments into agent prompt opts", %{} do
    parent = self()
    worker_name = String.to_atom("inbound_worker_media_#{System.unique_integer([:positive])}")
    image_path =
      Path.join(System.tmp_dir!(), "inbound_worker_media_#{System.unique_integer([:positive])}.png")

    File.write!(image_path, <<137, 80, 78, 71, 13, 10, 26, 10>>)
    on_exit(fn -> File.rm(image_path) end)

    prompt_fun = fn agent, prompt, opts ->
      send(parent, {:prompt_opts, prompt, Keyword.get(opts, :media)})
      {:ok, "done", agent}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-1",
        sender_id: "tester",
        text: "看图",
        message_type: :image,
        raw: %{},
        metadata: %{},
        media_refs: [],
        attachments: [
          %Attachment{
            id: "media_test",
            channel: "feishu",
            kind: :image,
            mime_type: "image/png",
            filename: "test.png",
            local_path: image_path,
            size_bytes: 8,
            source: :inbound,
            message_id: "om_test",
            platform_ref: %{"image_key" => "img_test"},
            metadata: %{}
          }
        ]
      }
    })

    assert_receive {:prompt_opts, "看图", media}, 1_000

    assert [%Attachment{local_path: ^image_path, kind: :image, mime_type: "image/png"}] = media
  end

  test "inbound worker creates new agents through configured agent_start_fun", %{
    workspace: workspace
  } do
    parent = self()
    worker_name = String.to_atom("inbound_worker_start_fun_#{System.unique_integer([:positive])}")

    start_fun = fn opts ->
      send(parent, {:agent_start_opts, opts})

      session_key = "#{Keyword.fetch!(opts, :channel)}:#{Keyword.fetch!(opts, :chat_id)}"

      {:ok,
       %Nex.Agent{
         session_key: session_key,
         session: Session.new(session_key),
         provider: Keyword.fetch!(opts, :provider),
         model: Keyword.fetch!(opts, :model),
         api_key: Keyword.get(opts, :api_key),
         base_url: Keyword.get(opts, :base_url),
         tools: Keyword.get(opts, :tools, %{}),
         workspace: Keyword.fetch!(opts, :workspace),
         cwd: Keyword.fetch!(opts, :cwd),
         max_iterations: Keyword.fetch!(opts, :max_iterations),
         runtime_version: Keyword.get(opts, :runtime_version)
       }}
    end

    prompt_fun = fn agent, prompt, _opts ->
      send(parent, {:prompt_agent, agent, prompt})
      {:ok, "done", agent}
    end

    start_supervised!(
      {InboundWorker, name: worker_name, agent_start_fun: start_fun, agent_prompt_fun: prompt_fun}
    )

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-start",
        sender_id: "tester",
        text: "hello",
        message_type: :text,
        raw: %{},
        metadata: %{},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:agent_start_opts, opts}, 1_000
    assert Keyword.get(opts, :workspace) == workspace
    assert Keyword.get(opts, :channel) == "feishu"
    assert Keyword.get(opts, :chat_id) == "chat-start"

    assert_receive {:prompt_agent, %Nex.Agent{} = agent, "hello"}, 1_000
    assert agent.session_key == "feishu:chat-start"
  end

  test "stale owner late result is dropped after stop and does not emit outbound", %{
    workspace: workspace
  } do
    parent = self()
    worker_name = String.to_atom("inbound_worker_stale_run_#{System.unique_integer([:positive])}")
    blocker = make_ref()

    prompt_fun = fn agent, prompt, opts ->
      send(parent, {:prompt_started, prompt, Keyword.get(opts, :owner_run_id)})

      receive do
        ^blocker ->
          {:ok, "#{prompt} done", %{agent | workspace: workspace}}
      after
        5_000 ->
          {:error, :timeout, %{agent | workspace: workspace}}
      end
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    worker = Process.whereis(worker_name)

    send(worker, {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-stale",
        sender_id: "tester",
        text: "long",
        message_type: :text,
        raw: %{},
        metadata: %{"workspace" => workspace},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:prompt_started, "long", owner_run_id}, 1_000
    assert is_binary(owner_run_id)

    send(worker, {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-stale",
        sender_id: "tester",
        text: "/stop",
        message_type: :text,
        raw: %{},
        metadata: %{"workspace" => workspace},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:bus_message, :feishu_outbound, stop_payload}, 1_000
    assert stop_payload.content =~ "Stopped 1 task(s)"

    send(worker, {:async_result, {Path.expand(workspace), "feishu:chat-stale"}, owner_run_id, {:ok, "late final", %Nex.Agent{workspace: workspace}}, %Envelope{
      channel: "feishu",
      chat_id: "chat-stale",
      sender_id: "tester",
      text: "long",
      message_type: :text,
      raw: %{},
      metadata: %{"workspace" => workspace},
      media_refs: [],
      attachments: []
    }})

    refute_receive {:bus_message, :feishu_outbound, _payload}, 300
  end

  test "busy ordinary message becomes a follow-up reply and does not queue into owner run", %{
    workspace: workspace
  } do
    parent = self()
    worker_name = String.to_atom("inbound_worker_follow_up_busy_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, prompt, opts ->
      send(parent, {:prompt_started, prompt, Keyword.get(opts, :owner_run_id)})
      Process.sleep(500)
      {:ok, "owner done", %{agent | workspace: workspace}}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})
    worker = Process.whereis(worker_name)

    send(worker, {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-follow-up",
        sender_id: "tester",
        text: "start long run",
        message_type: :text,
        raw: %{},
        metadata: %{"workspace" => workspace},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:prompt_started, "start long run", _owner_run_id}, 1_000

    send(worker, {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-follow-up",
        sender_id: "tester",
        text: "下载多少了？",
        message_type: :text,
        raw: %{},
        metadata: %{"workspace" => workspace},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:bus_message, :feishu_outbound, payload}, 1_000
    assert payload.metadata["_from_follow_up"] == true
    assert payload.content =~ "Owner run is still"

    assert_receive {:bus_message, :feishu_outbound, final_payload}, 1_000
    assert final_payload.content == "owner done"
  end

  test "/status and /btw are handled without calling llm and /queue on idle starts next owner turn", %{
    workspace: workspace
  } do
    parent = self()
    worker_name = String.to_atom("inbound_worker_status_queue_btw_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, prompt, _opts ->
      send(parent, {:owner_prompt, prompt})
      {:ok, "#{prompt} done", %{agent | workspace: workspace}}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})
    worker = Process.whereis(worker_name)

    send(worker, {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-status",
        sender_id: "tester",
        text: "/status",
        message_type: :text,
        raw: %{},
        metadata: %{"workspace" => workspace},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:bus_message, :feishu_outbound, idle_payload}, 1_000
    assert idle_payload.content == "Status: idle"

    send(worker, {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-status",
        sender_id: "tester",
        text: "/btw side question",
        message_type: :text,
        raw: %{},
        metadata: %{"workspace" => workspace},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:bus_message, :feishu_outbound, btw_payload}, 1_000
    assert btw_payload.content =~ "No owner run is active"
    assert btw_payload.metadata["_from_follow_up"] == true

    send(worker, {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-status",
        sender_id: "tester",
        text: "/queue next task",
        message_type: :text,
        raw: %{},
        metadata: %{"workspace" => workspace},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:bus_message, :feishu_outbound, queue_payload}, 1_000
    assert queue_payload.content =~ "Queued for next owner turn"
    assert_receive {:owner_prompt, "next task"}, 1_000
  end

  test "inbound workspace mismatch does not rewrite global runtime snapshot", %{
    workspace: workspace
  } do
    other_workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-inbound-other-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(other_workspace, "memory"))
    File.write!(Path.join(other_workspace, "AGENTS.md"), "# Other AGENTS\n")
    File.write!(Path.join(other_workspace, "memory/MEMORY.md"), "# Memory\n")

    on_exit(fn -> File.rm_rf!(other_workspace) end)

    assert {:ok, snapshot_before} = Runtime.reload(workspace: workspace)
    assert snapshot_before.workspace == workspace

    parent = self()
    worker_name = String.to_atom("inbound_worker_workspace_#{System.unique_integer([:positive])}")

    start_fun = fn opts ->
      send(parent, {:agent_start_opts, opts})

      session_key = "#{Keyword.fetch!(opts, :channel)}:#{Keyword.fetch!(opts, :chat_id)}"

      {:ok,
       %Nex.Agent{
         session_key: session_key,
         session: Session.new(session_key),
         provider: Keyword.fetch!(opts, :provider),
         model: Keyword.fetch!(opts, :model),
         workspace: Keyword.fetch!(opts, :workspace),
         cwd: Keyword.fetch!(opts, :cwd),
         max_iterations: Keyword.fetch!(opts, :max_iterations),
         runtime_version: Keyword.get(opts, :runtime_version)
       }}
    end

    prompt_fun = fn agent, _prompt, _opts -> {:ok, "done", agent} end

    start_supervised!(
      {InboundWorker, name: worker_name, agent_start_fun: start_fun, agent_prompt_fun: prompt_fun}
    )

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-other",
        sender_id: "tester",
        text: "hello",
        message_type: :text,
        raw: %{},
        metadata: %{"workspace" => other_workspace},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:agent_start_opts, opts}, 1_000
    assert Keyword.get(opts, :workspace) == Path.expand(other_workspace)
    assert Keyword.get(opts, :runtime_snapshot) == nil
    assert Keyword.get(opts, :runtime_version) == nil

    assert {:ok, snapshot_after} = Runtime.current()
    assert snapshot_after.workspace == workspace
    assert snapshot_after.version == snapshot_before.version
  end

  test "feishu reply via message tool does not append duplicate narration", %{
    workspace: workspace
  } do
    parent = self()
    worker_name = String.to_atom("inbound_worker_message_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, prompt, opts ->
      Process.put(:llm_call_count, 0)

      llm_stream_client = fn _messages, _llm_opts, callback ->
        case Process.get(:llm_call_count, 0) do
          0 ->
            Process.put(:llm_call_count, 1)
            callback.(
              {:tool_calls,
               [
                 %{
                   "id" => "call_message_reply",
                   "type" => "function",
                   "function" => %{
                     "name" => "message",
                     "arguments" => "{\"content\":\"收到 123 👋\"}"
                   }
                 }
               ]}
            )

            callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
            :ok

          _ ->
            send(parent, :message_tool_turn_finished)
            callback.({:delta, "已发送一个简单的表情回复。"})
            callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
            :ok
        end
      end

      runner_opts = [
        llm_stream_client: llm_stream_client,
        workspace: workspace,
        skip_consolidation: true,
        stream_sink: Keyword.get(opts, :stream_sink),
        channel: Keyword.get(opts, :channel),
        chat_id: Keyword.get(opts, :chat_id)
      ]

      case Runner.run(agent.session, prompt, runner_opts) do
        {:ok, result, session} -> {:ok, result, %{agent | session: session}}
        {:error, reason, session} -> {:error, reason, %{agent | session: session}}
      end
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-1",
        sender_id: "tester",
        text: "123",
        message_type: :text,
        raw: %{},
        metadata: %{},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive :message_tool_turn_finished, 1_000

    payloads = collect_feishu_payloads([])

    assert Enum.any?(payloads, fn payload ->
             payload.content == "收到 123 👋" and payload.metadata["_from_tool"] == true
           end)

    refute Enum.any?(payloads, &(&1.content == "已发送一个简单的表情回复。"))
    refute Enum.any?(payloads, &(&1.metadata["_progress"] == true))
  end

  test "inbound worker publishes final reply before background memory refresh finishes", %{
    workspace: workspace
  } do
    parent = self()
    worker_name = String.to_atom("inbound_worker_memory_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, _prompt, _opts ->
      updated_session =
        agent.session
        |> Session.add_message("user", "hello")
        |> Session.add_message("assistant", "final reply")
        |> then(fn session ->
          metadata =
            Map.merge(session.metadata || %{}, %{
              "memory_refresh_llm_call_fun" => fn _messages, _llm_opts ->
                send(parent, :memory_refresh_started)
                Process.sleep(200)

                {:ok,
                 %{
                   "status" => "update",
                   "memory_update" =>
                     "# Long-term Memory\n\n## User Preferences\n- Likes concise replies.\n"
                 }}
              end
            })

          %{session | metadata: metadata}
        end)

      {:ok, "final reply", %{agent | session: updated_session, workspace: workspace}}
    end

    start_supervised!({InboundWorker, name: worker_name, agent_prompt_fun: prompt_fun})

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-memory",
        sender_id: "tester",
        text: "hello",
        message_type: :text,
        raw: %{},
        metadata: %{},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:bus_message, :feishu_outbound, payload}, 1_000
    assert payload.content == "final reply"
    assert Memory.read_long_term(workspace: workspace) == "# Memory\n"

    assert_receive :memory_refresh_started, 1_000

    wait_for(fn ->
      Memory.read_long_term(workspace: workspace) =~ "Likes concise replies."
    end)
  end

  test "feishu stream sink updates card incrementally and suppresses default final outbound" do
    parent = self()
    worker_config = %Nex.Agent.Config{
      Nex.Agent.Config.default()
      | feishu: %{"enabled" => true, "streaming" => true}
    }

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_stream"}}}

        String.contains?(url, "/cardkit/v1/cards") ->
          {:ok, %{"code" => 0, "data" => %{"card_id" => "card_stream"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_put_fun = fn url, body, headers ->
      send(parent, {:http_put, url, body, headers})
      {:ok, %{"code" => 0, "data" => %{}}}
    end

    config = %Nex.Agent.Config{Nex.Agent.Config.default() | feishu: %{"enabled" => false}}

    if Process.whereis(Feishu), do: GenServer.stop(Feishu)

    start_supervised!(
      {Feishu,
       config: config,
       http_post_fun: http_post_fun,
       http_put_fun: http_put_fun,
       http_post_multipart_fun: fn _url, _body, _headers -> {:error, :unused} end,
       http_get_fun: fn _url, _headers -> {:error, :unused} end}
    )

    :sys.replace_state(Process.whereis(Feishu), fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    worker_name =
      String.to_atom("inbound_worker_feishu_stream_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, _prompt, opts ->
      sink = Keyword.fetch!(opts, :stream_sink)
      run_id = "run_stream_test"

      sink.({:text, "你好"})
      sink.({:text, "，哥"})
      sink.(:finish)

      {:ok,
       Result.ok(run_id, "你好，哥", %{
         "transport" => "feishu"
       }), agent}
    end

    start_supervised!(
      {InboundWorker, name: worker_name, config: worker_config, agent_prompt_fun: prompt_fun}
    )

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-stream",
        sender_id: "tester",
        text: "hello",
        message_type: :text,
        raw: %{},
        metadata: %{},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:http_post, auth_url, _auth_body, _auth_headers}, 1_000
    assert auth_url =~ "/auth/v3/tenant_access_token/internal"

    posts = collect_http_posts([])
    {card_url, card_body} = Enum.find(posts, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)
    assert card_url =~ "/cardkit/v1/cards"
    assert card_body["type"] == "card_json"

    {send_url, send_body} =
      Enum.find(posts, fn {url, body} -> url =~ "/im/v1/messages" and body["msg_type"] == "interactive" end)

    assert send_url =~ "/im/v1/messages"
    assert send_body["msg_type"] == "interactive"

    puts = collect_http_puts([])

    assert Enum.any?(puts, fn {put_url, _put_body} ->
             put_url =~ "/cardkit/v1/cards/card_stream/elements/content/content"
           end)

    assert Enum.any?(puts, fn {_put_url, put_body} ->
             put_body["content"] =~ "你好，哥"
           end)

    refute_receive {:bus_message, :feishu_outbound, _payload}, 300
  end

  test "feishu stream sink batches rapid deltas before updating card" do
    parent = self()
    worker_config = %Nex.Agent.Config{
      Nex.Agent.Config.default()
      | feishu: %{"enabled" => true, "streaming" => true}
    }

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_stream"}}}

        String.contains?(url, "/cardkit/v1/cards") ->
          {:ok, %{"code" => 0, "data" => %{"card_id" => "card_stream"}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_put_fun = fn url, body, headers ->
      send(parent, {:http_put, url, body, headers})
      {:ok, %{"code" => 0, "data" => %{}}}
    end

    config = %Nex.Agent.Config{Nex.Agent.Config.default() | feishu: %{"enabled" => false}}

    if Process.whereis(Feishu), do: GenServer.stop(Feishu)

    start_supervised!(
      {Feishu,
       config: config,
       http_post_fun: http_post_fun,
       http_put_fun: http_put_fun,
       http_post_multipart_fun: fn _url, _body, _headers -> {:error, :unused} end,
       http_get_fun: fn _url, _headers -> {:error, :unused} end}
    )

    :sys.replace_state(Process.whereis(Feishu), fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    worker_name =
      String.to_atom("inbound_worker_feishu_stream_batch_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, _prompt, opts ->
      sink = Keyword.fetch!(opts, :stream_sink)
      run_id = "run_stream_batch_test"

      sink.({:text, "你"})
      sink.({:text, "好"})
      sink.({:text, "，"})
      sink.({:text, "哥"})
      sink.(:finish)

      {:ok, Result.ok(run_id, "你好，哥", %{"transport" => "feishu"}), agent}
    end

    start_supervised!(
      {InboundWorker, name: worker_name, config: worker_config, agent_prompt_fun: prompt_fun}
    )

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "feishu",
        chat_id: "chat-stream-batch",
        sender_id: "tester",
        text: "hello",
        message_type: :text,
        raw: %{},
        metadata: %{},
        media_refs: [],
        attachments: []
      }
    })

    assert_receive {:http_post, _auth_url, _auth_body, _auth_headers}, 1_000
    _posts = collect_http_posts([])
    puts = collect_http_puts([])

    assert length(puts) == 2
    content_puts = Enum.filter(puts, fn {url, _body} -> url =~ "/elements/" end)
    assert length(content_puts) == 1
    assert Enum.at(content_puts, 0) |> elem(1) |> Map.fetch!("content") == "你好，哥"
  end

  test "discord stream sink edits current message and opens a new message on newmsg" do
    parent = self()
    worker_config = %Nex.Agent.Config{
      Nex.Agent.Config.default()
      | discord: %{"enabled" => true, "streaming" => true}
    }

    if Process.whereis(Discord), do: GenServer.stop(Discord)

    start_supervised!(
      {Discord,
       config: %Nex.Agent.Config{Nex.Agent.Config.default() | discord: %{"enabled" => false}},
       http_post_fun: fn url, body, headers ->
         send(parent, {:discord_http_post, url, body, headers})
         {:ok, %{"id" => "msg_" <> Integer.to_string(System.unique_integer([:positive]))}}
       end,
       http_patch_fun: fn url, body, headers ->
         send(parent, {:discord_http_patch, url, body, headers})
         {:ok, %{"id" => "patched"}}
       end}
    )

    :sys.replace_state(Process.whereis(Discord), fn state ->
      %{state | enabled: true, token: "discord-token"}
    end)

    worker_name =
      String.to_atom("inbound_worker_discord_stream_#{System.unique_integer([:positive])}")

    prompt_fun = fn agent, _prompt, opts ->
      sink = Keyword.fetch!(opts, :stream_sink)
      run_id = "run_discord_stream_test"

      sink.({:text, "第一段"})
      sink.({:text, "\n<newmsg/>\n第二"})
      sink.({:text, "段"})
      sink.(:finish)

      {:ok, Result.ok(run_id, "第一段\n<newmsg/>\n第二段", %{"transport" => "discord"}), agent}
    end

    start_supervised!(
      {InboundWorker, name: worker_name, config: worker_config, agent_prompt_fun: prompt_fun}
    )

    send(Process.whereis(worker_name), {
      :bus_message,
      :inbound,
      %Envelope{
        channel: "discord",
        chat_id: "discord-chat",
        sender_id: "tester",
        text: "hello",
        message_type: :text,
        raw: %{},
        metadata: %{},
        media_refs: [],
        attachments: []
      }
    })

    # Converter batches all chunks via 1s throttle, then splits by <newmsg/>.
    # First message: "第一段", Second message: "第二段"
    posts = collect_discord_posts([], 2_000)

    message_posts =
      Enum.filter(posts, fn {url, _body, _headers} ->
        url =~ "/channels/discord-chat/messages" and not (url =~ "/threads")
      end)

    contents = Enum.map(message_posts, fn {_url, body, _headers} -> body["content"] end)

    assert "第一段" in contents or Enum.any?(contents, &String.starts_with?(&1, "第一段"))
    assert "第二段" in contents or Enum.any?(contents, &String.contains?(&1, "第二段"))
    assert length(message_posts) >= 2

    refute_receive {:bus_message, :discord_outbound, _payload}, 300
  end

  defp collect_discord_posts(acc, timeout) do
    receive do
      {:discord_http_post, url, body, headers} ->
        collect_discord_posts([{url, body, headers} | acc], timeout)
      {:discord_http_patch, url, body, headers} ->
        collect_discord_posts([{url, body, headers} | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp collect_feishu_payloads(acc) do
    receive do
      {:bus_message, :feishu_outbound, payload} ->
        collect_feishu_payloads([payload | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp collect_http_puts(acc) do
    receive do
      {:http_put, url, body, _headers} ->
        collect_http_puts([{url, body} | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp collect_http_posts(acc) do
    receive do
      {:http_post, url, body, _headers} ->
        collect_http_posts([{url, body} | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp wait_for(predicate, attempts \\ 50)

  defp wait_for(_predicate, 0) do
    flunk("condition did not become true in time")
  end

  defp wait_for(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      wait_for(predicate, attempts - 1)
    end
  end

  defp stream_client_from_response(fun) when is_function(fun, 2) do
    fn messages, opts, callback ->
      case fun.(messages, opts) do
        {:ok, response} when is_map(response) ->
          content = Map.get(response, :content) || Map.get(response, "content") || ""

          case render_mock_content(content) do
            "" -> :ok
            text -> callback.({:delta, text})
          end

          tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || []

          if tool_calls != [] do
            callback.({:tool_calls, tool_calls})
          end

          callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp render_mock_content(nil), do: ""
  defp render_mock_content(text) when is_binary(text), do: text
  defp render_mock_content(text), do: inspect(text, printable_limit: 500, limit: 50)
end
