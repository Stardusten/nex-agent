defmodule Nex.Agent.RunnerStreamTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Runner, Session}
  alias Nex.Agent.Stream.Result

  test "runner emits unified stream events and preserves final session content" do
    parent = self()

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-runner-stream-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    stream_sink = fn event ->
      send(parent, {:stream_event, event})
      :ok
    end

    stream_text_fun = fn _model_spec, _messages, _opts ->
      {:ok,
       %{
         stream: [
           %{type: :content, text: "he"},
           %{type: :content, text: "llo"}
         ],
         finish_reason: :stop
       }}
    end

    assert {:ok, %Result{handled?: true, status: :ok, final_content: "hello"}, session} =
             Runner.run(Session.new("stream:test"), "hi",
               workspace: workspace,
               provider: :ollama,
               model: "qwen2.5:latest",
               base_url: "http://localhost:11434",
               skip_consolidation: true,
               skip_skills: true,
               stream_sink: stream_sink,
               req_llm_stream_text_fun: stream_text_fun
             )

    events = collect_stream_events([])

    assert [{:text, "he"}, {:text, "llo"}, :finish] = events

    assert List.last(session.messages)["content"] == "hello"
  end

  test "runner preserves whitespace and newlines in streamed text deltas" do
    parent = self()

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-runner-stream-markdown-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    stream_sink = fn event ->
      send(parent, {:stream_event, event})
      :ok
    end

    markdown = "# Title\n\n- item 1\n- item 2\n"

    stream_text_fun = fn _model_spec, _messages, _opts ->
      {:ok,
       %{
         stream: [
           %{type: :content, text: "#"},
           %{type: :content, text: " Title"},
           %{type: :content, text: "\n\n"},
           %{type: :content, text: "-"},
           %{type: :content, text: " item 1"},
           %{type: :content, text: "\n"},
           %{type: :content, text: "- item 2\n"}
         ],
         finish_reason: :stop
       }}
    end

    assert {:ok, %Result{handled?: true, status: :ok, final_content: ^markdown}, _session} =
             Runner.run(Session.new("stream:markdown"), "hi",
               workspace: workspace,
               provider: :ollama,
               model: "qwen2.5:latest",
               base_url: "http://localhost:11434",
               skip_consolidation: true,
               skip_skills: true,
               stream_sink: stream_sink,
               req_llm_stream_text_fun: stream_text_fun
             )

    assert [
             {:text, "#"},
             {:text, " Title"},
             {:text, "\n\n"},
             {:text, "-"},
             {:text, " item 1"},
             {:text, "\n"},
             {:text, "- item 2\n"},
             :finish
           ] = collect_stream_events([])
  end

  test "runner resets stream process state between runs in the same process" do
    parent = self()

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-runner-stream-reset-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    stream_sink = fn event ->
      send(parent, {:stream_event, event})
      :ok
    end

    stream_text_fun = fn _model_spec, _messages, _opts ->
      {:ok,
       %{
         stream: [%{type: :content, text: "ok"}],
         finish_reason: :stop
       }}
    end

    assert {:ok, %Result{handled?: true, final_content: "ok"}, _session} =
             Runner.run(Session.new("stream:test-1"), "hi",
               workspace: workspace,
               provider: :ollama,
               model: "qwen2.5:latest",
               base_url: "http://localhost:11434",
               skip_consolidation: true,
               skip_skills: true,
               stream_sink: stream_sink,
               req_llm_stream_text_fun: stream_text_fun
             )

    first_events = collect_stream_events([])

    assert [{:text, "ok"}, :finish] = first_events

    assert {:ok, %Result{handled?: true, final_content: "ok"}, _session} =
             Runner.run(Session.new("stream:test-2"), "again",
               workspace: workspace,
               provider: :ollama,
               model: "qwen2.5:latest",
               base_url: "http://localhost:11434",
               skip_consolidation: true,
               skip_skills: true,
               stream_sink: stream_sink,
               req_llm_stream_text_fun: stream_text_fun
             )

    second_events = collect_stream_events([])

    assert [{:text, "ok"}, :finish] = second_events
  end

  test "llm_stream_client injects native stream events without response replay in runner" do
    parent = self()

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-runner-stream-client-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    stream_sink = fn event ->
      send(parent, {:stream_event, event})
      :ok
    end

    response_fixture = fn _messages, _opts ->
      {:ok, %{content: "mock hello", finish_reason: nil, tool_calls: []}}
    end

    assert {:ok, %Result{handled?: true, status: :ok, final_content: "mock hello"}, _session} =
             Runner.run(Session.new("stream:test-client"), "hi",
               workspace: workspace,
               provider: :anthropic,
               model: "claude-sonnet-4-20250514",
               skip_consolidation: true,
               skip_skills: true,
               stream_sink: stream_sink,
               llm_stream_client: stream_client_from_response(response_fixture)
             )

    assert [{:text, "mock hello"}, :finish] = collect_stream_events([])
  end

  test "runner appends tool call notices into the stream before executing tools" do
    parent = self()

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-runner-stream-tools-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    stream_sink = fn event ->
      send(parent, {:stream_event, event})
      :ok
    end

    turn_key = {:tool_notice_turn, self()}
    Process.put(turn_key, 0)

    llm_stream_client = fn _messages, _opts, callback ->
      turn = Process.get(turn_key, 0)
      Process.put(turn_key, turn + 1)

      case turn do
        0 ->
          callback.(
            {:tool_calls,
             [
               %{
                 "id" => "call_1",
                 "function" => %{
                   "name" => "list_dir",
                   "arguments" => %{"path" => "."}
                 }
               }
             ]}
          )

          callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
          :ok

        1 ->
          callback.({:delta, "done"})
          callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
          :ok
      end
    end

    assert {:ok, %Result{handled?: true, status: :ok, final_content: "done"}, _session} =
             Runner.run(Session.new("stream:tool-call"), "hi",
               workspace: workspace,
               provider: :anthropic,
               model: "claude-sonnet-4-20250514",
               skip_consolidation: true,
               skip_skills: true,
               stream_sink: stream_sink,
               llm_stream_client: llm_stream_client
             )

    assert [{:text, "📂 ListDir - path=.\n"}, {:text, "\n"}, {:text, "done"}, :finish] =
             collect_stream_events([])
  end

  test "runner formats bash tool call notices with emoji and inline command" do
    parent = self()

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-runner-stream-bash-tools-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    on_exit(fn -> File.rm_rf!(workspace) end)

    stream_sink = fn event ->
      send(parent, {:stream_event, event})
      :ok
    end

    turn_key = {:bash_tool_notice_turn, self()}
    Process.put(turn_key, 0)

    llm_stream_client = fn _messages, _opts, callback ->
      turn = Process.get(turn_key, 0)
      Process.put(turn_key, turn + 1)

      case turn do
        0 ->
          callback.(
            {:tool_calls,
             [
               %{
                 "id" => "call_bash_1",
                 "function" => %{
                   "name" => "bash",
                   "arguments" => %{"command" => "ps aux | grep nex-agent"}
                 }
               }
             ]}
          )

          callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
          :ok

        1 ->
          callback.({:delta, "done"})
          callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
          :ok
      end
    end

    assert {:ok, %Result{handled?: true, status: :ok, final_content: "done"}, _session} =
             Runner.run(Session.new("stream:bash-tool-call"), "hi",
               workspace: workspace,
               provider: :anthropic,
               model: "claude-sonnet-4-20250514",
               skip_consolidation: true,
               skip_skills: true,
               stream_sink: stream_sink,
               llm_stream_client: llm_stream_client
             )

    assert [
             {:text, "⚙️ Bash - `ps aux | grep nex-agent`\n"},
             {:text, "\n"},
             {:text, "done"},
             :finish
           ] =
             collect_stream_events([])
  end

  defp collect_stream_events(acc) do
    receive do
      {:stream_event, event} ->
        collect_stream_events(acc ++ [event])
    after
      100 ->
        acc
    end
  end

  defp stream_client_from_response(fun) when is_function(fun, 2) do
    fn messages, opts, callback ->
      case fun.(messages, opts) do
        {:ok, response} when is_map(response) ->
          content = Map.get(response, :content) || Map.get(response, "content") || ""
          callback.({:delta, render_mock_content(content)})
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
