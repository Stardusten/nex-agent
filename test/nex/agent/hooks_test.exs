defmodule Nex.Agent.HooksTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{ContextBuilder, Hooks, Runner, Session}
  alias Nex.Agent.Runtime.Snapshot

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-hooks-#{System.unique_integer([:positive])}")

    kb_dir = Path.join(workspace, "kb")
    File.mkdir_p!(Path.join(workspace, "hooks"))
    File.mkdir_p!(kb_dir)
    File.write!(Path.join(kb_dir, "AGENTS.md"), "# KB Rules\nUse raw/webpages for clips.\n")

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace, kb_agents: Path.join(kb_dir, "AGENTS.md")}
  end

  test "missing registry yields empty hooks", %{workspace: workspace} do
    hooks = Hooks.load(workspace: workspace)

    assert hooks.entries == []
    assert hooks.diagnostics == []
    assert hooks.path == Hooks.registry_path(workspace: workspace)
    assert is_binary(hooks.hash)
  end

  test "invalid registry records diagnostics without crashing", %{workspace: workspace} do
    File.write!(Hooks.registry_path(workspace: workspace), "{bad json")

    hooks = Hooks.load(workspace: workspace)

    assert hooks.entries == []
    assert [%{"type" => "invalid_json"}] = hooks.diagnostics
  end

  test "enabled file and text hooks compile with stable hash", %{
    workspace: workspace,
    kb_agents: kb_agents
  } do
    write_hooks!(workspace, [
      %{
        "id" => "kb-agents",
        "event" => "prompt.build.before",
        "pointcut" => %{"session" => "discord:kb"},
        "advice" => %{
          "kind" => "file",
          "path" => kb_agents,
          "title" => "KB Instructions"
        }
      },
      %{
        "id" => "kb-thread",
        "event" => "prompt.build.before",
        "pointcut" => %{"session" => "discord:kb"},
        "advice" => %{
          "kind" => "text",
          "content" => "Bare links are ingest requests.",
          "priority" => 5
        }
      }
    ])

    first = Hooks.load(workspace: workspace)
    second = Hooks.load(workspace: workspace)

    assert length(first.entries) == 2
    assert first.hash == second.hash
    assert first.diagnostics == []
  end

  test "run matches session pointcut orders fragments and truncates", %{
    workspace: workspace,
    kb_agents: kb_agents
  } do
    File.write!(kb_agents, String.duplicate("x", 20))

    hooks = %{
      entries: [
        %{
          "id" => "late",
          "enabled" => true,
          "event" => "prompt.build.before",
          "pointcut" => %{"session" => "discord:kb"},
          "advice" => %{
            "kind" => "text",
            "content" => "late",
            "title" => "Late",
            "priority" => 50,
            "max_chars" => 12,
            "on_error" => "warn"
          }
        },
        %{
          "id" => "early",
          "enabled" => true,
          "event" => "prompt.build.before",
          "pointcut" => %{"session" => "discord:kb"},
          "advice" => %{
            "kind" => "file",
            "path" => kb_agents,
            "title" => "Early",
            "priority" => 1,
            "max_chars" => 5,
            "on_error" => "warn"
          }
        }
      ]
    }

    assert {:ok, fragments} =
             Hooks.run(:prompt_build_before, hooks, %{
               session_key: "discord:kb",
               channel: "discord",
               chat_id: "kb",
               workspace: workspace
             })

    assert Enum.map(fragments, & &1["id"]) == ["early", "late"]
    assert hd(fragments)["content"] == "xxxxx"
    assert hd(fragments)["truncated"] == true
  end

  test "file advice rejects directories according to on_error policy", %{workspace: workspace} do
    hooks = %{
      entries: [
        %{
          "id" => "warn-dir",
          "enabled" => true,
          "event" => "prompt.build.before",
          "pointcut" => %{"session" => "discord:kb"},
          "advice" => %{
            "kind" => "file",
            "path" => workspace,
            "title" => "Directory Hook",
            "priority" => 1,
            "on_error" => "warn"
          }
        },
        %{
          "id" => "skip-dir",
          "enabled" => true,
          "event" => "prompt.build.before",
          "pointcut" => %{"session" => "discord:kb"},
          "advice" => %{
            "kind" => "file",
            "path" => workspace,
            "title" => "Skipped Directory Hook",
            "priority" => 2,
            "on_error" => "skip"
          }
        }
      ]
    }

    assert {:ok, [warning]} =
             Hooks.run(:prompt_build_before, hooks, %{
               session_key: "discord:kb",
               workspace: workspace
             })

    assert warning["kind"] == "warning"
    assert warning["content"] =~ "hook file must be a regular file"

    blocking_hooks = %{
      hooks
      | entries: [
          %{
            "id" => "block-dir",
            "enabled" => true,
            "event" => "prompt.build.before",
            "pointcut" => %{"session" => "discord:kb"},
            "advice" => %{
              "kind" => "file",
              "path" => workspace,
              "title" => "Blocking Directory Hook",
              "priority" => 1,
              "on_error" => "block"
            }
          }
        ]
    }

    assert {:error, reason} =
             Hooks.run(:prompt_build_before, blocking_hooks, %{
               session_key: "discord:kb",
               workspace: workspace
             })

    assert reason =~ "hook file must be a regular file"
  end

  test "file advice rejects symlink-resolved forbidden paths", %{workspace: workspace} do
    home_link = Path.join(workspace, "home-link")
    File.ln_s!(System.user_home!(), home_link)

    hooks = %{
      entries: [
        %{
          "id" => "blocked-config",
          "enabled" => true,
          "event" => "prompt.build.before",
          "pointcut" => %{"session" => "discord:kb"},
          "advice" => %{
            "kind" => "file",
            "path" => Path.join(home_link, ".nex/agent/config.json"),
            "title" => "Blocked Config",
            "on_error" => "block"
          }
        }
      ]
    }

    assert {:error, reason} =
             Hooks.run(:prompt_build_before, hooks, %{
               session_key: "discord:kb",
               workspace: workspace
             })

    assert reason =~ "hook file path is blocked"
  end

  test "text advice preserves literal content", %{workspace: workspace} do
    literal = "  keep leading whitespace\nand trailing newline\n"

    hooks = %{
      entries: [
        %{
          "id" => "literal",
          "enabled" => true,
          "event" => "prompt.build.before",
          "pointcut" => %{"session" => "discord:kb"},
          "advice" => %{
            "kind" => "text",
            "content" => literal,
            "title" => "Literal Text",
            "priority" => 1,
            "on_error" => "warn"
          }
        }
      ]
    }

    assert {:ok, [fragment]} =
             Hooks.run(:prompt_build_before, hooks, %{
               session_key: "discord:kb",
               workspace: workspace
             })

    assert fragment["content"] == literal

    messages =
      ContextBuilder.build_messages([], "hello", "discord", "kb", nil,
        workspace: workspace,
        system_prompt: "Base",
        context_hook_fragments: [fragment]
      )

    system = messages |> List.first() |> Map.fetch!("content")
    assert system =~ "\n\n  keep leading whitespace\nand trailing newline\n"
  end

  test "runner injects matching file hook without a read tool call", %{
    workspace: workspace,
    kb_agents: kb_agents
  } do
    parent = self()

    snapshot = %Snapshot{
      version: 1,
      workspace: workspace,
      prompt: %{system_prompt: "Base system prompt", diagnostics: [], hash: "prompt"},
      tools: %{
        definitions_all: [],
        definitions_follow_up: [],
        definitions_subagent: [],
        definitions_cron: [],
        hash: "tools"
      },
      hooks: %{
        entries: [
          %{
            "id" => "kb-agents",
            "enabled" => true,
            "event" => "prompt.build.before",
            "pointcut" => %{"session" => "discord:kb"},
            "advice" => %{
              "kind" => "file",
              "path" => kb_agents,
              "title" => "KB Instructions",
              "priority" => 1,
              "max_chars" => 12_000,
              "on_error" => "warn"
            }
          }
        ],
        diagnostics: [],
        hash: "hooks",
        path: Hooks.registry_path(workspace: workspace),
        version: 1
      }
    }

    llm_client = fn messages, opts ->
      send(parent, {:messages, messages, Keyword.get(opts, :tools, [])})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    assert {:ok, "ok", _session} =
             Runner.run(Session.new("discord:kb"), "hello",
               llm_stream_client: stream_client_from_response(llm_client),
               runtime_snapshot: snapshot,
               workspace: workspace,
               channel: "discord",
               chat_id: "kb",
               skip_consolidation: true,
               skip_skills: true,
               tool_allowlist: []
             )

    assert_receive {:messages, messages, tools}

    system = messages |> List.first() |> Map.fetch!("content")
    assert system =~ "## Context Hook: KB Instructions"
    assert system =~ "# KB Rules"
    assert tools == []
  end

  test "nonmatching session does not receive hook", %{workspace: workspace, kb_agents: kb_agents} do
    hooks = %{
      entries: [
        %{
          "id" => "kb-agents",
          "enabled" => true,
          "event" => "prompt.build.before",
          "pointcut" => %{"session" => "discord:kb"},
          "advice" => %{
            "kind" => "file",
            "path" => kb_agents,
            "title" => "KB Instructions",
            "priority" => 1,
            "max_chars" => 12_000,
            "on_error" => "warn"
          }
        }
      ]
    }

    assert {:ok, []} =
             Hooks.run(:prompt_build_before, hooks, %{
               session_key: "discord:other",
               channel: "discord",
               chat_id: "other",
               workspace: workspace
             })
  end

  test "old pinned_prompt metadata is ignored", %{workspace: workspace} do
    messages =
      ContextBuilder.build_messages([], "hello", "discord", "kb", nil,
        workspace: workspace,
        system_prompt: "Base",
        context_hook_fragments: []
      )

    system = messages |> List.first() |> Map.fetch!("content")
    refute system =~ "Session Pinned Prompt"
  end

  defp write_hooks!(workspace, hooks) do
    path = Hooks.registry_path(workspace: workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"version" => 1, "hooks" => hooks}, pretty: true))
  end

  defp stream_client_from_response(fun) when is_function(fun, 2) do
    fn messages, opts, callback ->
      case fun.(messages, opts) do
        {:ok, response} when is_map(response) ->
          emit_mock_stream_response(callback, response)
          :ok

        other ->
          other
      end
    end
  end

  defp emit_mock_stream_response(callback, response) do
    content = Map.get(response, :content) || Map.get(response, "content") || ""
    if content != "", do: callback.({:delta, content})

    tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || []
    if tool_calls != [], do: callback.({:tool_calls, tool_calls})

    callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
  end
end
