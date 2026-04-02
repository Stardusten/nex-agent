defmodule NexAgentConsole.RuntimePanelTest do
  use ExUnit.Case, async: true

  alias NexAgentConsole.Components.AdminUI
  alias NexAgentConsole.Support.View

  test "runtime panel explains when request trace is disabled" do
    html =
      base_runtime_state(%{
        request_trace_config: %{"enabled" => false, "dir" => "audit/request_traces"}
      })
      |> then(&AdminUI.runtime_panel(%{state: &1}))
      |> View.render()

    assert html =~ "Request trace 当前关闭"
    assert html =~ "request_trace.enabled"
  end

  test "runtime panel renders recent trace summaries" do
    html =
      base_runtime_state(%{
        request_trace_config: %{"enabled" => true, "dir" => "audit/request_traces"},
        recent_request_traces: [
          %{
            run_id: "run_trace_1",
            prompt: "show me the trace",
            status: "completed",
            tool_count: 2,
            llm_rounds: 3,
            selected_packages: [%{"name" => "agent-browser"}],
            used_tools: ["list_dir", "skill_run__agent_browser"],
            skill_call_count: 1
          }
        ]
      })
      |> then(&AdminUI.runtime_panel(%{state: &1, trace_mode: :index}))
      |> View.render()

    assert html =~ "run_trace_1"
    assert html =~ "show me the trace"
    assert html =~ "3 rounds"
    assert html =~ "agent-browser"
    assert html =~ "进入详情页查看"
    refute html =~ "当前请求"
  end

  test "runtime panel renders selected trace detail" do
    html =
      base_runtime_state(%{
        request_trace_config: %{"enabled" => true, "dir" => "audit/request_traces"},
        recent_request_traces: [
          %{
            run_id: "run_trace_2",
            prompt: "detail",
            status: "completed",
            tool_count: 1,
            llm_rounds: 1,
            selected_packages: []
          }
        ],
        selected_request_trace: %{
          run_id: "run_trace_2",
          prompt: "detail prompt",
          status: "completed",
          channel: "telegram",
          chat_id: "chat-1",
          llm_rounds: 1,
          tool_count: 1,
          used_tools: ["list_dir", "skill_run__agent_browser"],
          selected_packages: [%{"name" => "agent-browser"}],
          runtime_system_messages: ["[Skill Runtime] Use the selected package."],
          result: "final answer",
          available_tools: [
            %{name: "list_dir", description: "List files", parameters: %{"type" => "object"}},
            %{name: "skill_run__agent_browser", description: "Run browser skill", parameters: %{}}
          ],
          tool_activity: [
            %{
              kind: :tool,
              name: "list_dir",
              tool_call_id: "call_1",
              iteration: 1,
              arguments: %{"path" => "."},
              result: "ok"
            },
            %{
              kind: :skill,
              name: "skill_run__agent_browser",
              tool_call_id: "call_2",
              iteration: 1,
              arguments: %{"task" => "open"},
              result: "done"
            }
          ],
          llm_turns: [
            %{
              iteration: 1,
              inserted_at: "2026-03-30T12:00:01Z",
              message_count: 3,
              tool_calls: [%{name: "list_dir"}, %{name: "skill_run__agent_browser"}],
              available_tool_names: ["list_dir", "skill_run__agent_browser"],
              content: "thinking",
              finish_reason: nil,
              duration_ms: 200,
              request: %{"messages" => []},
              response: %{"content" => "thinking"}
            }
          ],
          events: [
            %{
              "type" => "request_started",
              "run_id" => "run_trace_2",
              "prompt" => "detail prompt"
            },
            %{
              "type" => "llm_request",
              "run_id" => "run_trace_2",
              "iteration" => 1,
              "messages" => [%{"role" => "system", "content" => "hi"}],
              "tools" => []
            },
            %{
              "type" => "llm_response",
              "run_id" => "run_trace_2",
              "iteration" => 1,
              "content" => "thinking"
            },
            %{
              "type" => "tool_result",
              "run_id" => "run_trace_2",
              "tool" => "list_dir",
              "content" => "ok"
            },
            %{
              "type" => "request_completed",
              "run_id" => "run_trace_2",
              "status" => "completed",
              "result" => "final answer"
            }
          ]
        }
      })
      |> then(&AdminUI.runtime_panel(%{state: &1, trace_mode: :detail}))
      |> View.render()

    assert html =~ "这一页只看一条 request trace"
    assert html =~ "detail prompt"
    assert html =~ "skill 命中"
    assert html =~ "tool 调用"
    assert html =~ "agent 回合"
    assert html =~ "skill:agent_browser"
    assert html =~ "Round 1"
    assert html =~ "Request Started"
    assert html =~ "final answer"
  end

  defp base_runtime_state(overrides) do
    Map.merge(
      %{
        gateway: %{
          status: :stopped,
          started_at: nil,
          config: %{provider: "anthropic", model: "kimi-k2.5"},
          services: %{"gateway" => true}
        },
        heartbeat: %{enabled: false, running: false, interval: nil},
        directories: [%{name: "audit", exists: true}],
        recent_request_traces: [],
        selected_request_trace: nil,
        request_trace_config: %{"enabled" => false, "dir" => "audit/request_traces"}
      },
      overrides
    )
  end
end
