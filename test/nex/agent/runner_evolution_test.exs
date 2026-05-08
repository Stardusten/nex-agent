defmodule Nex.Agent.Test.MalformedTool do
  @behaviour Nex.Agent.Capability.Tool.Behaviour

  def name, do: "malformed_tool"
  def description, do: "Returns a bare map instead of a tagged tuple"
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      }
    }
  end

  def execute(_args, _ctx), do: %{success: false, output: 0}
end

defmodule Nex.Agent.Test.SecretFailTool do
  @behaviour Nex.Agent.Capability.Tool.Behaviour

  def name, do: "secret_fail_tool"
  def description, do: "Fails while receiving secret-like args"
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      }
    }
  end

  def execute(_args, _ctx), do: {:error, "forced failure"}
end

defmodule Nex.Agent.Test.BigOutputTool do
  @behaviour Nex.Agent.Capability.Tool.Behaviour

  def name, do: "big_output_tool"
  def description, do: "Returns a large deterministic output"
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      }
    }
  end

  def execute(_args, _ctx), do: {:ok, String.duplicate("a", 5_000)}
end

defmodule Nex.Agent.Turn.RunnerEvolutionTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{
    App.Bus,
    Turn.ContextBuilder,
    Interface.Media.Attachment,
    App.Onboarding,
    Observe.Compat.RequestTrace,
    Turn.Runner,
    Conversation.Session,
    Conversation.SessionManager,
    Capability.Skills
  }

  alias Nex.Agent.Observe.ControlPlane.Query, as: ControlPlaneQuery

  @feishu_instance "feishu_runner_evolution"
  @feishu_topic {:channel_outbound, @feishu_instance}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-runner-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "skills"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)
    Skills.load()

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    if Process.whereis(SessionManager) == nil do
      start_supervised!({SessionManager, name: SessionManager})
    end

    if Process.whereis(Nex.Agent.Capability.Tool.Registry) == nil do
      start_supervised!(
        {Nex.Agent.Capability.Tool.Registry, name: Nex.Agent.Capability.Tool.Registry}
      )
    end

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "runner includes media in the user message content", %{workspace: workspace} do
    parent = self()
    image_path = Path.join(workspace, "runner-media.png")
    File.write!(image_path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

    llm_client = fn messages, _opts ->
      send(parent, {:messages, messages})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    media = [
      %Attachment{
        id: "media_runner",
        channel: "feishu",
        kind: :image,
        mime_type: "image/png",
        filename: "runner-media.png",
        local_path: image_path,
        size_bytes: 8,
        source: :inbound,
        message_id: "om_runner",
        platform_ref: %{"image_key" => "img_runner"},
        metadata: %{}
      }
    ]

    {:ok, _result, _session} =
      Runner.run(Session.new("runner-media"), "这张图里是什么",
        llm_stream_client: stream_client_from_response(llm_client),
        media: media,
        workspace: workspace,
        skip_consolidation: true,
        channel: "feishu",
        chat_id: "ou_test"
      )

    assert_receive {:messages, messages}
    user_message = List.last(messages)

    assert user_message["role"] == "user"
    assert is_list(user_message["content"])

    assert Enum.any?(user_message["content"], fn
             %{
               "type" => "image",
               "source" => %{
                 "path" => ^image_path,
                 "media_type" => "image/png"
               }
             } ->
               true

             _ ->
               false
           end)
  end

  test "runner records request trace for a plain assistant response", %{workspace: workspace} do
    llm_client = fn _messages, _opts ->
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    {:ok, _result, _session} =
      Runner.run(Session.new("trace-basic"), "show trace",
        llm_stream_client: stream_client_from_response(llm_client),
        workspace: workspace,
        request_trace: %{"enabled" => true},
        skip_consolidation: true,
        channel: "telegram",
        chat_id: "trace"
      )

    [path] = RequestTrace.list_paths(workspace: workspace, request_trace: %{"enabled" => true})

    events =
      RequestTrace.read_trace(path, workspace: workspace, request_trace: %{"enabled" => true})

    run_id = hd(events)["run_id"]

    request_events =
      Enum.filter(events, fn event ->
        event["type"] in [
          "request_started",
          "llm_request",
          "llm_response",
          "request_completed"
        ]
      end)

    assert Enum.any?(events, &(&1["type"] == "runner.run.started"))

    assert Enum.map(request_events, & &1["type"]) == [
             "request_started",
             "llm_request",
             "llm_response",
             "request_completed"
           ]

    assert Enum.all?(events, &(&1["run_id"] == run_id))
    assert Enum.at(request_events, 2)["content_summary"] == "ok"
    assert Enum.at(request_events, 3)["result_summary"] == "ok"
  end

  test "runner records runner.llm.call.failed control-plane observation on final LLM failure", %{
    workspace: workspace
  } do
    llm_client = fn _messages, _opts -> {:error, :timeout} end

    assert {:error, :timeout, _session} =
             Runner.run(Session.new("self-healing-llm"), "fail once",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true,
               llm_retry_delay_ms: 0,
               run_id: "run_self_healing_llm"
             )

    assert [event] = control_plane_logs(workspace, tag: "runner.llm.call.failed")
    assert event["tag"] == "runner.llm.call.failed"
    assert event["context"]["run_id"] == "run_self_healing_llm"
    assert event["attrs"]["actor"]["component"] == "runner"
    assert event["attrs"]["evidence"]["error_text"] =~ "timeout"
  end

  test "runner records run and llm lifecycle observations on successful runs", %{
    workspace: workspace
  } do
    llm_client = fn _messages, _opts ->
      {:ok, %{content: "ok", finish_reason: "stop", tool_calls: []}}
    end

    assert {:ok, "ok", _session} =
             Runner.run(Session.new("runner-lifecycle"), "hello",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true,
               run_id: "run_lifecycle_success",
               session_key: "session:lifecycle",
               channel: "telegram",
               chat_id: "chat-lifecycle"
             )

    tags =
      workspace
      |> control_plane_logs(run_id: "run_lifecycle_success")
      |> Enum.map(& &1["tag"])

    assert "runner.run.started" in tags
    assert "runner.llm.call.started" in tags
    assert "runner.llm.call.finished" in tags
    assert "runner.run.finished" in tags

    assert [finished] =
             control_plane_logs(workspace,
               tag: "runner.llm.call.finished",
               run_id: "run_lifecycle_success"
             )

    assert finished["attrs"]["finish_reason"] == "stop"
    assert finished["attrs"]["tool_call_count"] == 0
    refute inspect(finished) =~ "cancel_ref"
  end

  test "runner treats incomplete LLM response as failure and records context evidence", %{
    workspace: workspace
  } do
    llm_client = fn _messages, _opts ->
      {:ok,
       %{
         content: "",
         finish_reason: "incomplete",
         incomplete_reason: "max_output_tokens",
         usage: %{
           input_tokens: 100,
           cached_input_tokens: 0,
           output_tokens: 4096,
           reasoning_output_tokens: 4000,
           total_tokens: 4196
         },
         tool_calls: []
       }}
    end

    assert {:error, result, session} =
             Runner.run(Session.new("runner-incomplete"), "hello",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true,
               run_id: "run_lifecycle_incomplete",
               session_key: "session:incomplete",
               channel: "discord",
               chat_id: "chat-incomplete"
             )

    assert result =~ "incomplete response"
    refute Enum.any?(session.messages, &(&1["role"] == "assistant"))

    assert [incomplete] =
             control_plane_logs(workspace,
               tag: "runner.llm.call.incomplete",
               run_id: "run_lifecycle_incomplete"
             )

    assert incomplete["attrs"]["finish_reason"] == "incomplete"
    assert incomplete["attrs"]["incomplete_reason"] == "max_output_tokens"

    assert %{"last_incomplete" => %{"reason" => "max_output_tokens"}} =
             session.metadata["context_window_v2"]
  end

  test "runner retries terminal-event incomplete once with trimmed history", %{
    workspace: workspace
  } do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    parent = self()

    llm_client = fn messages, _opts ->
      send(parent, {:messages, length(messages)})
      turn = Agent.get_and_update(counter, &{&1, &1 + 1})

      case turn do
        0 ->
          {:ok,
           %{
             content: "",
             finish_reason: "incomplete",
             incomplete_reason: "stream_ended_without_terminal_event",
             tool_calls: []
           }}

        _ ->
          {:ok, %{content: "ok after retry", finish_reason: nil, tool_calls: []}}
      end
    end

    session =
      Enum.reduce(1..20, Session.new("runner-incomplete-retry"), fn idx, session ->
        session
        |> Session.add_message("user", "question #{idx}")
        |> Session.add_message("assistant", String.duplicate("answer #{idx} ", 200))
      end)

    assert {:ok, "ok after retry", _session} =
             Runner.run(session, "hello",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true,
               run_id: "run_lifecycle_incomplete_retry",
               session_key: "session:incomplete-retry",
               channel: "discord",
               chat_id: "chat-incomplete-retry"
             )

    assert_receive {:messages, first_count}
    assert_receive {:messages, second_count}
    assert second_count < first_count

    assert [retry] =
             control_plane_logs(workspace,
               tag: "runner.llm.incomplete_retry",
               run_id: "run_lifecycle_incomplete_retry"
             )

    assert retry["attrs"]["retry_strategy"] == "trim_history"
    assert retry["attrs"]["incomplete_reason"] == "stream_ended_without_terminal_event"
  end

  test "runner truncates tool output using context window token budget", %{
    workspace: workspace
  } do
    Nex.Agent.Capability.Tool.Registry.register(Nex.Agent.Test.BigOutputTool)
    wait_for_registry_tool("big_output_tool", Nex.Agent.Test.BigOutputTool)

    on_exit(fn ->
      Nex.Agent.Capability.Tool.Registry.unregister("big_output_tool")
      Nex.Agent.Capability.Tool.Registry.list()
    end)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    llm_client = fn _messages, _opts ->
      turn = Agent.get_and_update(counter, &{&1, &1 + 1})

      case turn do
        0 ->
          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "call_big_output",
                 function: %{
                   name: "big_output_tool",
                   arguments: %{}
                 }
               }
             ]
           }}

        _ ->
          {:ok, %{content: "done", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, "done", session} =
             Runner.run(Session.new("runner-tool-output-budget"), "run big output",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true,
               run_id: "run_tool_output_budget",
               session_key: "session:tool-output-budget",
               channel: "discord",
               chat_id: "chat-tool-output-budget",
               model_runtime: %{
                 provider: :anthropic,
                 model_id: "claude-sonnet-4-20250514",
                 provider_options: [],
                 context_window: 5_000
               },
               provider_options: [max_tokens: 100]
             )

    assert Enum.any?(session.messages, fn
             %{"role" => "tool", "content" => content} -> content =~ "truncated to"
             _ -> false
           end)

    assert [truncated] =
             control_plane_logs(workspace,
               tag: "runner.context_window.tool_output.truncated",
               run_id: "run_tool_output_budget"
             )

    assert truncated["attrs"]["tool_name"] == "big_output_tool"
  end

  test "runner records runner.tool.call.failed control-plane observation for tool errors", %{
    workspace: workspace
  } do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    llm_client = fn _messages, _opts ->
      turn = Agent.get_and_update(counter, &{&1, &1 + 1})

      case turn do
        0 ->
          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "call_missing",
                 function: %{name: "missing_tool", arguments: %{"value" => "boom"}}
               }
             ]
           }}

        _ ->
          {:ok, %{content: "done", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, "done", _session} =
             Runner.run(Session.new("self-healing-tool"), "use missing tool",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true,
               run_id: "run_self_healing_tool"
             )

    assert [event] = control_plane_logs(workspace, tag: "runner.tool.call.failed")
    assert event["tag"] == "runner.tool.call.failed"
    assert event["context"]["run_id"] == "run_self_healing_tool"
    assert event["attrs"]["actor"]["tool"] == "missing_tool"
    assert event["attrs"]["evidence"]["error_text"] =~ "Unknown tool"

    tags =
      workspace
      |> control_plane_logs(run_id: "run_self_healing_tool")
      |> Enum.map(& &1["tag"])

    assert "runner.tool.batch.started" in tags
    assert "runner.tool.batch.finished" in tags
    assert "runner.tool.call.started" in tags
    assert "runner.tool.call.failed" in tags

    assert Enum.count(tags, &(&1 == "runner.tool.call.failed")) == 1
  end

  test "runner failed tool evidence uses redacted bounded args summary", %{workspace: workspace} do
    Nex.Agent.Capability.Tool.Registry.register(Nex.Agent.Test.SecretFailTool)
    wait_for_registry_tool("secret_fail_tool", Nex.Agent.Test.SecretFailTool)

    on_exit(fn ->
      Nex.Agent.Capability.Tool.Registry.unregister("secret_fail_tool")
      Nex.Agent.Capability.Tool.Registry.list()
    end)

    secret = "sk-runner-secret"
    command = "echo token=#{secret}"

    llm_client = fn messages, _opts ->
      if Enum.any?(messages, &(&1["role"] == "tool" and &1["name"] == "secret_fail_tool")) do
        {:ok, %{content: "done", finish_reason: nil, tool_calls: []}}
      else
        {:ok,
         %{
           content: "",
           finish_reason: nil,
           tool_calls: [
             %{
               id: "call_secret_fail",
               function: %{
                 name: "secret_fail_tool",
                 arguments: %{"command" => command}
               }
             }
           ]
         }}
      end
    end

    assert {:ok, "done", _session} =
             Runner.run(Session.new("runner-secret-tool-failure"), "trigger secret failure",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true,
               run_id: "run_secret_tool_failure"
             )

    assert [event] =
             control_plane_logs(workspace,
               tag: "runner.tool.call.failed",
               run_id: "run_secret_tool_failure"
             )

    evidence_summary = event["attrs"]["evidence"]["args_summary"]
    assert is_binary(evidence_summary)
    assert String.length(evidence_summary) <= 1000
    assert evidence_summary =~ "[REDACTED]"
    refute inspect(event) =~ secret
  end

  test "runner records tool results in request trace", %{
    workspace: workspace
  } do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    llm_client = fn _messages, _opts ->
      turn =
        Agent.get_and_update(counter, fn current ->
          {current, current + 1}
        end)

      case turn do
        0 ->
          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{id: "call_1", function: %{name: "list_dir", arguments: %{"path" => "."}}}
             ]
           }}

        _ ->
          {:ok, %{content: "done", finish_reason: nil, tool_calls: []}}
      end
    end

    {:ok, _result, _session} =
      Runner.run(Session.new("trace-tools"), "inspect workspace",
        llm_stream_client: stream_client_from_response(llm_client),
        workspace: workspace,
        request_trace: %{"enabled" => true},
        skip_consolidation: true
      )

    [trace_path] =
      RequestTrace.list_paths(workspace: workspace, request_trace: %{"enabled" => true})

    trace_events =
      RequestTrace.read_trace(trace_path,
        workspace: workspace,
        request_trace: %{"enabled" => true}
      )

    assert Enum.count(trace_events, &(&1["type"] == "llm_request")) == 2
    assert Enum.count(trace_events, &(&1["type"] == "llm_response")) == 2
    assert Enum.count(trace_events, &(&1["type"] == "tool_result")) == 1
  end

  test "complex task sets next-turn skill nudge and skill creation clears it", %{
    workspace: workspace
  } do
    llm_client_first = fn _messages, _opts ->
      {:ok,
       %{
         content: "",
         finish_reason: nil,
         tool_calls: [
           %{id: "a", function: %{name: "list_dir", arguments: %{"path" => "."}}},
           %{id: "b", function: %{name: "read", arguments: %{"path" => "AGENTS.md"}}},
           %{id: "c", function: %{name: "read", arguments: %{"path" => "SOUL.md"}}},
           %{id: "d", function: %{name: "read", arguments: %{"path" => "TOOLS.md"}}}
         ]
       }}
    end

    {:ok, _result, session_after_first} =
      Runner.run(Session.new("skill-nudge"), "先分析一下项目",
        llm_stream_client: stream_client_from_response(llm_client_first),
        workspace: workspace,
        cwd: workspace,
        skip_consolidation: true
      )

    assert get_in(session_after_first.metadata, ["runtime_evolution", "pending_skill_nudge"]) ==
             true

    parent = self()

    llm_client_second = fn messages, _opts ->
      send(parent, {:messages, messages})

      {:ok,
       %{
         content: "",
         finish_reason: nil,
         tool_calls: [
           %{
             id: "skill_capture",
             function: %{
               name: "skill_capture",
               arguments: %{
                 "name" => "project-inspection",
                 "description" => "Inspect a project before changes",
                 "content" => "Read README, inspect mix.exs, then list important files."
               }
             }
           }
         ]
       }}
    end

    {:ok, _result, session_after_second} =
      Runner.run(session_after_first, "把刚才的方法沉淀一下",
        llm_stream_client: stream_client_from_response(llm_client_second),
        workspace: workspace,
        cwd: workspace,
        skip_consolidation: true
      )

    assert_receive {:messages, messages}

    assert Enum.any?(
             messages,
             &(&1["role"] == "system" and
                 String.contains?(&1["content"], "previous task was complex"))
           )

    assert get_in(session_after_second.metadata, ["runtime_evolution", "pending_skill_nudge"]) ==
             false
  end

  test "structured tool arguments do not crash unified event emission", %{workspace: workspace} do
    llm_client = fn _messages, _opts ->
      {:ok,
       %{
         content: "thinking",
         finish_reason: nil,
         tool_calls: [
           %{
             id: "call_bad_args",
             function: %{
               name: "list_dir",
               arguments: [%{"a" => 1}]
             }
           }
         ]
       }}
    end

    assert {:ok, _result, _session} =
             Runner.run(Session.new("runner-structured-args"), "trigger structured args",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true
             )
  end

  test "runner does not crash when a tool returns a bare map", %{workspace: workspace} do
    Nex.Agent.Capability.Tool.Registry.register(Nex.Agent.Test.MalformedTool)
    assert "malformed_tool" in Nex.Agent.Capability.Tool.Registry.list()

    on_exit(fn ->
      Nex.Agent.Capability.Tool.Registry.unregister("malformed_tool")
      Nex.Agent.Capability.Tool.Registry.list()
    end)

    llm_client = fn messages, _opts ->
      if Enum.any?(messages, &(&1["role"] == "tool" and &1["name"] == "malformed_tool")) do
        {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
      else
        {:ok,
         %{
           content: "",
           finish_reason: nil,
           tool_calls: [
             %{
               id: "call_malformed_tool",
               function: %{
                 name: "malformed_tool",
                 arguments: %{}
               }
             }
           ]
         }}
      end
    end

    assert {:ok, "ok", session} =
             Runner.run(Session.new("runner-malformed-tool"), "trigger malformed tool",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true
             )

    assert Enum.any?(session.messages, fn
             %{"role" => "tool", "name" => "malformed_tool", "content" => content} ->
               content =~ "\"success\": false" and content =~ "\"output\": 0"

             _ ->
               false
           end)
  end

  test "structured model content does not crash unified event handling", %{
    workspace: workspace
  } do
    llm_client = fn _messages, _opts ->
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
    end

    assert {:ok, _result, _session} =
             Runner.run(Session.new("runner-structured-content"), "trigger structured content",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true
             )
  end

  test "workspace-global USER.md is shared across session keys by design", %{
    workspace: workspace
  } do
    File.write!(
      Path.join(workspace, "USER.md"),
      "# USER\nShared profile preference for this workspace.\n"
    )

    parent = self()

    llm_client = fn messages, opts ->
      send(parent, {:messages, opts[:session_key], messages})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    {:ok, _result, telegram_session} =
      Runner.run(Session.new("telegram:1"), "hello from telegram",
        llm_stream_client: stream_client_from_response(llm_client),
        workspace: workspace,
        skip_consolidation: true,
        session_key: "telegram:1",
        channel: "telegram",
        chat_id: "1"
      )

    {:ok, _result, discord_session} =
      Runner.run(Session.new("discord:2"), "hello from discord",
        llm_stream_client: stream_client_from_response(llm_client),
        workspace: workspace,
        skip_consolidation: true,
        session_key: "discord:2",
        channel: "discord",
        chat_id: "2"
      )

    assert_receive {:messages, "telegram:1", telegram_messages}
    assert_receive {:messages, "discord:2", discord_messages}

    telegram_system = Enum.find(telegram_messages, &(&1["role"] == "system"))["content"]
    discord_system = Enum.find(discord_messages, &(&1["role"] == "system"))["content"]

    assert telegram_system =~ "Shared profile preference for this workspace"
    assert telegram_system =~ "all channels use the same durable context"
    assert discord_system =~ "Shared profile preference for this workspace"
    assert discord_system =~ "all channels use the same durable context"
    assert telegram_system == discord_system

    assert Enum.any?(telegram_session.messages, &(&1["content"] == "hello from telegram"))
    refute Enum.any?(telegram_session.messages, &(&1["content"] == "hello from discord"))
    assert Enum.any?(discord_session.messages, &(&1["content"] == "hello from discord"))
    refute Enum.any?(discord_session.messages, &(&1["content"] == "hello from telegram"))
  end

  test "runner preserves assistant tool calls when history window would otherwise start at tool result",
       %{workspace: workspace} do
    parent = self()
    tool_call_id = "read_19"
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    session =
      %{
        Session.new("runner-tool-boundary")
        | messages: [
            %{"role" => "user", "content" => "开始", "timestamp" => now},
            %{
              "role" => "assistant",
              "content" => "让我继续看错误处理部分：",
              "timestamp" => now,
              "tool_calls" => [
                %{
                  "id" => tool_call_id,
                  "type" => "function",
                  "function" => %{
                    "name" => "read",
                    "arguments" => Jason.encode!(%{"path" => "lib/nex/agent/runner.ex"})
                  }
                }
              ]
            },
            %{
              "role" => "tool",
              "content" => "defmodule Nex.Agent.Turn.Runner do\n",
              "timestamp" => now,
              "tool_call_id" => tool_call_id,
              "name" => "read"
            }
            | Enum.map(1..49, fn idx ->
                %{
                  "role" => "assistant",
                  "content" => "后续分析 #{idx}",
                  "timestamp" => now
                }
              end)
          ]
      }

    llm_client = fn messages, _opts ->
      send(parent, {:messages, messages})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    assert {:ok, "ok", _updated_session} =
             Runner.run(session, "继续",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true
             )

    assert_receive {:messages, messages}

    history_messages =
      messages
      |> Enum.reject(&(&1["role"] == "system"))
      |> Enum.drop(-1)

    assert hd(history_messages)["role"] == "assistant"
    assert get_in(hd(history_messages), ["tool_calls"]) |> hd() |> Map.get("id") == tool_call_id
    assert Enum.at(history_messages, 1)["role"] == "tool"
    assert Enum.at(history_messages, 1)["tool_call_id"] == tool_call_id
  end

  test "message tool to current chat suppresses follow-up direct reply", %{workspace: workspace} do
    parent = self()
    Bus.subscribe(@feishu_topic)
    on_exit(fn -> Bus.unsubscribe(@feishu_topic) end)

    llm_client = fn _messages, _opts ->
      case Process.get(:llm_call_count, 0) do
        0 ->
          Process.put(:llm_call_count, 1)

          {:ok,
           %{
             content: "我直接回一条。",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "call_message_current",
                 function: %{
                   name: "message",
                   arguments: %{"content" => "收到 123 👋"}
                 }
               }
             ]
           }}

        _ ->
          send(parent, :runner_current_message_done)
          {:ok, %{content: "已发送一个简单的表情回复。", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, :message_sent, _session} =
             Runner.run(Session.new("#{@feishu_instance}:ou_current"), "123",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true,
               channel: @feishu_instance,
               chat_id: "ou_current"
             )

    assert_receive :runner_current_message_done

    assert_receive {:bus_message, @feishu_topic, payload}
    assert payload.content == "收到 123 👋"
    assert payload.metadata["_from_tool"] == true
  end

  test "message tool to another chat does not suppress current reply", %{workspace: workspace} do
    parent = self()
    Bus.subscribe(@feishu_topic)
    on_exit(fn -> Bus.unsubscribe(@feishu_topic) end)

    llm_client = fn _messages, _opts ->
      case Process.get(:llm_call_count, 0) do
        0 ->
          Process.put(:llm_call_count, 1)

          {:ok,
           %{
             content: "我顺手通知另一个会话。",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "call_message_other",
                 function: %{
                   name: "message",
                   arguments: %{
                     "content" => "给另一个会话的通知",
                     "channel" => @feishu_instance,
                     "chat_id" => "ou_other"
                   }
                 }
               }
             ]
           }}

        _ ->
          send(parent, :runner_other_message_done)
          {:ok, %{content: "当前会话的最终回复", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, "当前会话的最终回复", _session} =
             Runner.run(Session.new("#{@feishu_instance}:ou_current"), "123",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true,
               channel: @feishu_instance,
               chat_id: "ou_current"
             )

    assert_receive :runner_other_message_done

    assert_receive {:bus_message, @feishu_topic, payload}
    assert payload.chat_id == "ou_other"
    assert payload.content == "给另一个会话的通知"
  end

  test "call_llm_for_consolidation retries anthropic match errors without tool_choice" do
    parent = self()

    llm_stream_text_fun = fn _model_spec, _messages, opts ->
      send(parent, {:consolidation_opts, opts})

      case Process.get(:runner_consolidation_retry_count, 0) do
        0 ->
          Process.put(:runner_consolidation_retry_count, 1)
          raise %MatchError{term: {:error, :not_implemented}}

        _ ->
          {:ok,
           %{
             stream: [
               %{
                 type: :tool_call,
                 name: "save_memory",
                 arguments: %{
                   "history_entry" => "[2026-03-18 13:00] Anthropic retry worked.",
                   "memory_update" => "# Memory\n\nRetry path succeeded.\n"
                 }
               }
             ],
             finish_reason: :stop
           }}
      end
    end

    assert {:ok,
            %{
              "history_entry" => "[2026-03-18 13:00] Anthropic retry worked.",
              "memory_update" => "# Memory\n\nRetry path succeeded.\n"
            }} =
             Runner.call_llm_for_consolidation(consolidation_messages(),
               provider: :anthropic,
               model: "claude-sonnet-4-20250514",
               tools: [save_memory_tool_definition()],
               tool_choice: %{type: "tool", name: "save_memory"},
               req_llm_stream_text_fun: llm_stream_text_fun
             )

    assert_receive {:consolidation_opts, first_opts}
    assert_receive {:consolidation_opts, second_opts}
    assert first_opts[:tool_choice] == %{type: "tool", name: "save_memory"}
    refute Keyword.has_key?(second_opts, :tool_choice)
  end

  test "call_llm_for_consolidation retries openai model engine errors without tool_choice" do
    parent = self()

    llm_stream_text_fun = fn _model_spec, _messages, opts ->
      send(parent, {:consolidation_opts, opts})

      case Process.get(:runner_consolidation_retry_count, 0) do
        0 ->
          Process.put(:runner_consolidation_retry_count, 1)

          {:error,
           %ReqLLM.Error.API.Request{
             reason: "model engine error",
             status: 500,
             response_body: %{
               "code" => "20057",
               "message" => "model engine error",
               "type" => "runtime_error"
             }
           }}

        _ ->
          {:ok,
           %{
             stream: [
               %{
                 type: :tool_call,
                 name: "save_memory",
                 arguments: %{
                   "history_entry" => "[2026-04-27 10:50] OpenAI retry worked.",
                   "memory_update" => "# Memory\n\nOpenAI retry path succeeded.\n"
                 }
               }
             ],
             finish_reason: :stop
           }}
      end
    end

    assert {:ok,
            %{
              "history_entry" => "[2026-04-27 10:50] OpenAI retry worked.",
              "memory_update" => "# Memory\n\nOpenAI retry path succeeded.\n"
            }} =
             Runner.call_llm_for_consolidation(consolidation_messages(),
               provider: :openai,
               model: "hy3-preview",
               tools: [save_memory_tool_definition()],
               tool_choice: %{type: "tool", name: "save_memory"},
               req_llm_stream_text_fun: llm_stream_text_fun
             )

    assert_receive {:consolidation_opts, first_opts}
    assert_receive {:consolidation_opts, second_opts}
    assert first_opts[:tool_choice] == %{type: "tool", name: "save_memory"}
    refute Keyword.has_key?(second_opts, :tool_choice)
  end

  test "call_llm_for_consolidation returns non-retryable errors unchanged" do
    parent = self()

    llm_stream_text_fun = fn _model_spec, _messages, opts ->
      send(parent, {:consolidation_opts, opts})
      {:error, "upstream unavailable"}
    end

    assert {:error, "upstream unavailable"} =
             Runner.call_llm_for_consolidation(consolidation_messages(),
               provider: :anthropic,
               model: "claude-sonnet-4-20250514",
               tools: [save_memory_tool_definition()],
               tool_choice: %{type: "tool", name: "save_memory"},
               req_llm_stream_text_fun: llm_stream_text_fun
             )

    assert_receive {:consolidation_opts, first_opts}
    assert first_opts[:tool_choice] == %{type: "tool", name: "save_memory"}
    refute_receive {:consolidation_opts, _}
  end

  test "onboarding and composition tolerate legacy content without silent mutation" do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-onboarding-regression-#{System.unique_integer([:positive])}"
      )

    config_path = Path.join(base_dir, "config.json")
    workspace = Path.join(base_dir, "workspace")

    legacy_user = "# USER\nYou are ChatGPT for all replies.\n"

    File.write!(Path.join(workspace, "USER.md"), legacy_user)

    Application.put_env(:nex_agent, :agent_base_dir, base_dir)
    Application.put_env(:nex_agent, :config_path, config_path)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :agent_base_dir)
      Application.delete_env(:nex_agent, :config_path)
      File.rm_rf!(base_dir)
    end)

    :ok = Onboarding.ensure_initialized()

    {prompt, diagnostics} =
      ContextBuilder.build_system_prompt_with_diagnostics(workspace: workspace)

    assert prompt =~ "You are ChatGPT for all replies"
    assert Enum.any?(diagnostics, fn diagnostic ->
             diagnostic.source == "USER.md" and
               diagnostic.category == :identity_persona_instruction_in_user
           end)

    assert File.read!(Path.join(workspace, "USER.md")) == legacy_user
  end

  defp consolidation_messages do
    [
      %{"role" => "system", "content" => "Use the save_memory tool."},
      %{"role" => "user", "content" => "Persist this summary."}
    ]
  end

  defp save_memory_tool_definition do
    %{
      "type" => "function",
      "function" => %{
        "name" => "save_memory",
        "description" => "Save the memory consolidation result to persistent storage.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "history_entry" => %{"type" => "string"},
            "memory_update" => %{"type" => "string"}
          },
          "required" => ["history_entry", "memory_update"]
        }
      }
    }
  end

  defp build_consolidation_messages(count) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    for idx <- 1..count do
      role = if rem(idx, 2) == 1, do: "user", else: "assistant"
      %{"role" => role, "content" => "message #{idx}", "timestamp" => now}
    end
  end

  defp tool_name_from_definition(%{"function" => %{"name" => name}}), do: name
  defp tool_name_from_definition(%{function: %{name: name}}), do: name
  defp tool_name_from_definition(%{name: name}), do: name
  defp tool_name_from_definition(_), do: nil

  defp wait_for_value(fun, predicate, attempts \\ 40)
  defp wait_for_value(fun, _predicate, 0), do: fun.()

  defp wait_for_value(fun, predicate, attempts) do
    value = fun.()

    if predicate.(value) do
      value
    else
      Process.sleep(25)
      wait_for_value(fun, predicate, attempts - 1)
    end
  end

  defp control_plane_logs(workspace, filters) do
    filters
    |> Map.new()
    |> ControlPlaneQuery.query(workspace: workspace)
    |> case do
      {:ok, %{"observations" => observations}} -> observations
      {:ok, %{observations: observations}} -> observations
      {:ok, observations} when is_list(observations) -> observations
      observations when is_list(observations) -> observations
    end
  end

  defp wait_for_registry_tool(name, module, attempts \\ 20)
  defp wait_for_registry_tool(_name, _module, 0), do: :ok

  defp wait_for_registry_tool(name, module, attempts) do
    if Nex.Agent.Capability.Tool.Registry.get(name) == module do
      :ok
    else
      Process.sleep(10)
      wait_for_registry_tool(name, module, attempts - 1)
    end
  end

  defp stream_client_from_response(fun) when is_function(fun, 2) do
    fn messages, opts, callback ->
      case fun.(messages, opts) do
        {:ok, response} when is_map(response) ->
          emit_mock_stream_response(callback, response)
          :ok

        {:error, reason} ->
          {:error, reason}

        response when is_map(response) ->
          emit_mock_stream_response(callback, response)
          :ok

        other ->
          other
      end
    end
  end

  defp emit_mock_stream_response(callback, response) do
    reasoning_content =
      Map.get(response, :reasoning_content) || Map.get(response, "reasoning_content")

    if is_binary(reasoning_content) and String.trim(reasoning_content) != "" do
      callback.({:thinking, reasoning_content})
    end

    content = Map.get(response, :content) || Map.get(response, "content") || ""

    if is_binary(content) do
      case render_mock_content(content) do
        "" -> :ok
        text -> callback.({:delta, text})
      end
    end

    tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || []

    if tool_calls != [] do
      callback.({:tool_calls, tool_calls})
    end

    metadata =
      response
      |> Map.take([
        :incomplete_reason,
        "incomplete_reason",
        :incomplete_details,
        "incomplete_details"
      ])
      |> Map.merge(%{
        finish_reason: Map.get(response, :finish_reason) || Map.get(response, "finish_reason"),
        usage: Map.get(response, :usage) || Map.get(response, "usage"),
        model: Map.get(response, :model) || Map.get(response, "model")
      })

    callback.({:done, metadata})
  end

  defp render_mock_content(nil), do: ""
  defp render_mock_content(text) when is_binary(text), do: text
  defp render_mock_content(text), do: inspect(text, printable_limit: 500, limit: 50)
end
