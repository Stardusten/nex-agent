defmodule Nex.Agent.RunnerStreamTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Runner, Session}
  alias Nex.Agent.Stream.Result

  defmodule TransportError do
    defexception [:message]
  end

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

  test "runner resumes interrupted stream with continue prompt and preserves partial output" do
    parent = self()

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-runner-stream-continue-#{System.unique_integer([:positive])}"
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

    turn_key = {:stream_continue_turn, self()}
    Process.put(turn_key, 0)

    llm_stream_client = fn messages, _opts, callback ->
      turn = Process.get(turn_key, 0)
      Process.put(turn_key, turn + 1)

      case turn do
        0 ->
          callback.({:delta, "hello "})
          {:error, %TransportError{message: "connection closed"}}

        1 ->
          assert %{"role" => "assistant", "content" => "hello "} = Enum.at(messages, -2)

          assert %{"role" => "user", "content" => continue_prompt} = Enum.at(messages, -1)
          assert continue_prompt =~ "Continue from the exact breakpoint"
          assert continue_prompt =~ "Do not repeat any text"

          callback.({:delta, "world"})
          callback.({:done, %{finish_reason: "stop", usage: nil, model: "mock-model"}})
          :ok
      end
    end

    assert {:ok, %Result{handled?: true, status: :ok, final_content: "hello world"}, session} =
             Runner.run(Session.new("stream:continue"), "hi",
               workspace: workspace,
               provider: :anthropic,
               model: "claude-sonnet-4-20250514",
               skip_consolidation: true,
               skip_skills: true,
               stream_sink: stream_sink,
               llm_stream_client: llm_stream_client,
               llm_retry_delay_ms: 0
             )

    assert [{:text, "hello "}, {:text, "world"}, :finish] = collect_stream_events([])
    assert List.last(session.messages)["content"] == "hello world"
  end

  test "runner persists generated images from response metadata and returns artifact paths" do
    parent = self()

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-runner-image-generation-#{System.unique_integer([:positive])}"
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

    llm_stream_client = fn _messages, _opts, callback ->
      callback.(
        {:done,
         %{
           finish_reason: "stop",
           usage: %{tool_usage: %{image_generation: %{count: 1, unit: :call}}},
           model: "gpt-5.3-codex",
           generated_images: [
             %{
               "result" => Base.encode64(tiny_png_bytes()),
               "mime_type" => "image/png",
               "revised_prompt" => "A lighthouse watercolor"
             }
           ]
         }}
      )

      :ok
    end

    assert {:ok, %Result{handled?: true, status: :ok} = result, session} =
             Runner.run(Session.new("stream:image-generation"), "generate image",
               workspace: workspace,
               provider: :openai_codex,
               model: "gpt-5.3-codex",
               base_url: "https://chatgpt.com/backend-api/codex",
               skip_consolidation: true,
               skip_skills: true,
               stream_sink: stream_sink,
               llm_stream_client: llm_stream_client
             )

    assert [{:text, text}, :finish] = collect_stream_events([])
    assert text =~ "Generated images:"

    [generated] = result.metadata[:generated_images]
    assert File.exists?(generated["path"])
    assert generated["mime_type"] == "image/png"
    assert generated["revised_prompt"] == "A lighthouse watercolor"
    assert result.final_content =~ generated["path"]
    assert List.last(session.messages)["content"] =~ generated["path"]
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

  defp tiny_png_bytes do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0,
      1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 11, 73, 68, 65, 84, 120, 156, 99, 96,
      0, 2, 0, 0, 5, 0, 1, 122, 94, 171, 63, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
