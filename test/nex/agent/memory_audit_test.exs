defmodule Nex.Agent.MemoryAuditTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.ContextBuilder
  alias Nex.Agent.Memory
  alias Nex.Agent.Runner
  alias Nex.Agent.Session
  alias Nex.Agent.Tool.Registry

  setup_all do
    backup_dir =
      Path.join(System.tmp_dir!(), "nex_agent_memory_parity_backup_#{System.unique_integer([:positive])}")

    original_exists = File.exists?(memory_dir())

    if original_exists do
      copy_dir_contents!(memory_dir(), backup_dir)
    end

    reset_memory_dir()

    on_exit(fn ->
      File.rm_rf(memory_dir())

      if original_exists do
        copy_dir_contents!(backup_dir, memory_dir())
      else
        File.mkdir_p!(memory_dir())
      end

      File.rm_rf(backup_dir)
    end)

    :ok
  end

  setup do
    reset_memory_dir()
    :ok
  end

  describe "session parity" do
    test "get_history aligns to first user message and preserves partial tool transcript" do
      session =
        Session.new("audit:tool-pairs")
        |> put_messages([
          %{"role" => "assistant", "content" => "orphan intro"},
          %{"role" => "user", "content" => "find issue"},
          %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{"id" => "call_1", "function" => %{"name" => "read", "arguments" => %{"path" => "a.ex"}}},
              %{"id" => "call_2", "function" => %{"name" => "read", "arguments" => %{"path" => "b.ex"}}}
            ],
            "reasoning_content" => "hidden"
          },
          %{
            "role" => "tool",
            "tool_call_id" => "call_1",
            "name" => "read",
            "content" => "contents"
          }
        ])

      assert [
               %{"role" => "user", "content" => "find issue"},
               %{"role" => "assistant", "tool_calls" => [%{"id" => "call_1"}, %{"id" => "call_2"}]},
               %{"role" => "tool", "tool_call_id" => "call_1", "name" => "read", "content" => "contents"}
             ] = Session.get_history(session, 10)
    end

    test "get_history keeps assistant-led slice when there is no user turn" do
      session =
        Session.new("audit:no-user")
        |> put_messages([
          %{"role" => "assistant", "content" => "partial"},
          %{"role" => "tool", "tool_call_id" => "call_1", "name" => "read", "content" => "result"}
        ])

      assert [
               %{"role" => "assistant", "content" => "partial"},
               %{"role" => "tool", "tool_call_id" => "call_1", "name" => "read", "content" => "result"}
             ] = Session.get_history(session, 10)
    end

    test "get_history preserves tool-led slices when max_messages truncates away the user turn" do
      session =
        Session.new("audit:tool-led")
        |> put_messages([
          %{"role" => "user", "content" => "start"},
          %{"role" => "assistant", "content" => "", "tool_calls" => [%{"id" => "call_1"}]},
          %{"role" => "tool", "tool_call_id" => "call_1", "name" => "read", "content" => "result"}
        ])

      assert [
               %{"role" => "tool", "tool_call_id" => "call_1", "name" => "read", "content" => "result"}
             ] = Session.get_history(session, 1)
    end
  end

  describe "context parity" do
    test "build_messages merges runtime context into plain-text user message" do
      File.write!(Path.join(memory_dir(), "MEMORY.md"), "remember me")

      [system, user] =
        ContextBuilder.build_messages([], "hello world", "telegram", "1001", nil,
          workspace: Memory.workspace_path(),
          skip_skills: true
        )

      assert system["role"] == "system"
      assert system["content"] =~ "# Memory\n\n## Long-term Memory\nremember me"
      refute system["content"] =~ "Relevant Memories"

      assert user["role"] == "user"
      assert user["content"] =~ "[Runtime Context"
      assert user["content"] =~ "Channel: telegram"
      assert user["content"] =~ "Chat ID: 1001"
      assert user["content"] =~ "hello world"
    end

    test "build_messages prepends runtime context as first text block for media content" do
      [_, user] =
        ContextBuilder.build_messages([], "caption", "telegram", "1001", [%{"type" => "image", "url" => "https://x/y.jpg"}],
          workspace: Memory.workspace_path(),
          skip_skills: true
        )

      assert is_list(user["content"])
      assert hd(user["content"])["type"] == "text"
      assert hd(user["content"])["text"] =~ "[Runtime Context"
      assert List.last(user["content"])["text"] == "caption"
    end

    test "full memory is injected once into system prompt without retrieval block" do
      tail = String.duplicate("tailneedle ", 800)
      File.write!(Path.join(memory_dir(), "MEMORY.md"), tail)

      [system, _user] =
        ContextBuilder.build_messages([], "tailneedle", "telegram", "1001", nil,
          workspace: Memory.workspace_path(),
          skip_skills: true
        )

      assert system["content"] =~ tail
      refute system["content"] =~ "Relevant Memories"
    end

    test "build_system_prompt reads memory from the provided workspace" do
      custom_workspace =
        Path.join(System.tmp_dir!(), "nex_agent_custom_workspace_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(custom_workspace, "memory"))
      File.write!(Path.join(custom_workspace, "memory/MEMORY.md"), "workspace-specific memory")

      on_exit(fn -> File.rm_rf(custom_workspace) end)

      [system, _user] =
        ContextBuilder.build_messages([], "hello", "telegram", "1001", nil,
          workspace: custom_workspace,
          skip_skills: true
        )

      assert system["content"] =~ "workspace-specific memory"
      refute system["content"] =~ "remember me"
    end
  end

  describe "memory consolidation parity" do
    test "runner parses list-wrapped tool arguments like nanobot" do
      assert %{"history_entry" => "ok"} =
               Runner.parse_tool_arguments([%{"history_entry" => "ok"}])
    end

    test "consolidate advances session on valid dict result" do
      session =
        Session.new("audit:consolidate-dict")
        |> put_messages(sample_messages())

      {:ok, updated} =
        Memory.consolidate(session, :openai, "test-model",
          memory_window: 4,
          llm_call_fun: fn _messages, _opts ->
            {:ok,
             %{
               "history_entry" => "[2026-03-10 10:00] summarized only",
               "memory_update" => "## facts\nupdated"
             }}
          end
        )

      assert updated.last_consolidated == length(session.messages) - 2
      assert Memory.read_long_term() == "## facts\nupdated"
    end

    test "consolidate accepts JSON string arguments" do
      session =
        Session.new("audit:consolidate-json")
        |> put_messages(sample_messages())

      {:ok, updated} =
        Memory.consolidate(session, :openai, "test-model",
          memory_window: 4,
          llm_call_fun: fn _messages, _opts ->
            {:ok, ~s({"history_entry":"[2026-03-10 10:00] json","memory_update":"## facts\\njson"})}
          end
        )

      assert updated.last_consolidated == length(session.messages) - 2
      assert Memory.read_long_term() == "## facts\njson"
    end

    test "consolidate accepts list-wrapped dict arguments" do
      session =
        Session.new("audit:consolidate-list")
        |> put_messages(sample_messages())

      {:ok, updated} =
        Memory.consolidate(session, :openai, "test-model",
          memory_window: 4,
          llm_call_fun: fn _messages, _opts ->
            {:ok, [%{"history_entry" => "[2026-03-10 10:00] list", "memory_update" => "## facts\nlist"}]}
          end
        )

      assert updated.last_consolidated == length(session.messages) - 2
      assert Memory.read_long_term() == "## facts\nlist"
    end

    test "consolidate fails and does not advance session when no tool call payload is returned" do
      session =
        Session.new("audit:consolidate-fail")
        |> put_messages(sample_messages())

      assert {:error, _reason} =
               Memory.consolidate(session, :openai, "test-model",
                 memory_window: 4,
                 llm_call_fun: fn _messages, _opts -> {:ok, %{}} end
               )

      assert session.last_consolidated == 0
      assert Memory.read_long_term() == ""
    end
  end

  describe "default extensions removed" do
    test "memory index is not started by default" do
      refute Process.whereis(Nex.Agent.Memory.Index)
    end

    test "memory_search is not in the default tool registry" do
      ensure_started(Registry, fn -> Registry.start_link() end)
      refute "memory_search" in Registry.list()
    end
  end

  defp put_messages(session, messages), do: %{session | messages: messages}

  defp reset_memory_dir do
    dir = memory_dir()
    File.rm_rf(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "MEMORY.md"), "")
    File.write!(Path.join(dir, "HISTORY.md"), "")
  end

  defp memory_dir do
    Path.join(Memory.workspace_path(), "memory")
  end

  defp copy_dir_contents!(source, destination) do
    if File.dir?(source) do
      File.mkdir_p!(destination)

      source
      |> File.ls!()
      |> Enum.each(fn name ->
        {:ok, _files} = File.cp_r(Path.join(source, name), Path.join(destination, name))
      end)
    else
      :ok
    end
  end

  defp sample_messages do
    [
      %{"role" => "user", "content" => "one", "timestamp" => "2026-03-10T10:00:00Z"},
      %{"role" => "assistant", "content" => "two", "timestamp" => "2026-03-10T10:00:01Z"},
      %{"role" => "user", "content" => "three", "timestamp" => "2026-03-10T10:00:02Z"},
      %{"role" => "assistant", "content" => "four", "timestamp" => "2026-03-10T10:00:03Z"},
      %{"role" => "user", "content" => "five", "timestamp" => "2026-03-10T10:00:04Z"},
      %{"role" => "assistant", "content" => "six", "timestamp" => "2026-03-10T10:00:05Z"}
    ]
  end

  defp ensure_started(name, start_fun) do
    unless Process.whereis(name) do
      start_fun.()
    end
  end
end
