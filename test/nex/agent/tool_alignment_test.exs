defmodule Nex.Agent.TestSkillMessageTool do
  @behaviour Nex.Agent.Tool.Behaviour

  def name, do: "skill_message"
  def description, do: "Test tool that collides with skill-generated name."
  def category, do: :base

  def definition do
    %{
      name: "skill_message",
      description: description(),
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      }
    }
  end

  def execute(_args, _ctx), do: {:ok, "ok"}
end

defmodule Nex.Agent.ToolAlignmentTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Runner, Session, Skills}
  alias Nex.Agent.Runtime.Snapshot

  alias Nex.Agent.Tool.{
    EvolutionCandidate,
    Registry,
    SkillDiscover,
    SkillGet,
    SoulUpdate,
    ToolList
  }

  alias Nex.SkillRuntime

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-alignment-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    Application.put_env(:nex_agent, :workspace_path, workspace)

    Skills.load()

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Registry) == nil do
      start_supervised!({Registry, name: Registry})
    end

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      Registry.unregister("skill_message")

      if pid = Process.whereis(Skills) do
        try do
          Agent.update(pid, &Map.delete(&1, "message"))
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "soul_update writes SOUL.md in configured workspace", %{workspace: workspace} do
    assert {:ok, _} = SoulUpdate.execute(%{"content" => "# Soul\nStay precise.\n"}, %{})
    assert File.read!(Path.join(workspace, "SOUL.md")) =~ "Stay precise."
  end

  test "tool_list exposes split user and memory layers" do
    assert {:ok, result} = ToolList.execute(%{"scope" => "builtin"}, %{})

    builtins = result[:builtin]
    memory_consolidate = Enum.find(builtins, &(&1["name"] == "memory_consolidate"))
    memory_rebuild = Enum.find(builtins, &(&1["name"] == "memory_rebuild"))
    memory_status = Enum.find(builtins, &(&1["name"] == "memory_status"))
    memory_write = Enum.find(builtins, &(&1["name"] == "memory_write"))
    reflect = Enum.find(builtins, &(&1["name"] == "reflect"))
    self_update = Enum.find(builtins, &(&1["name"] == "self_update"))
    skill_get = Enum.find(builtins, &(&1["name"] == "skill_get"))
    skill_capture = Enum.find(builtins, &(&1["name"] == "skill_capture"))
    tool_create = Enum.find(builtins, &(&1["name"] == "tool_create"))

    assert memory_consolidate["layers"] == ["memory"]
    assert memory_rebuild["layers"] == ["memory"]
    assert memory_status["layers"] == ["memory"]
    assert memory_write["layers"] == ["memory"]
    assert reflect["layers"] == ["code"]
    assert self_update["layers"] == ["code"]
    assert skill_get["layers"] == ["skill"]
    assert skill_capture["layers"] == ["skill"]
    assert tool_create["layers"] == ["tool"]
    assert Enum.find(builtins, &(&1["name"] == "evolution_candidate"))["layers"] == ["tool"]
    refute Enum.any?(builtins, &(&1["name"] == "skill_list"))
    refute Enum.any?(builtins, &(&1["name"] == "skill_read"))
    refute Enum.any?(builtins, &(&1["name"] == "skill_create"))
    refute Enum.any?(builtins, &String.starts_with?(&1["name"], "feishu_"))
  end

  test "skills stay discoverable resources instead of expanding into synthetic tools", %{
    workspace: workspace
  } do
    Agent.update(Skills, fn skills ->
      Map.put(skills, "message", %{
        name: "message",
        description: "Creates a colliding skill tool name.",
        parameters: %{},
        user_invocable: true,
        content: "Return the input unchanged."
      })
    end)

    Registry.register(Nex.Agent.TestSkillMessageTool)
    wait_for_registry_tool("skill_message", Nex.Agent.TestSkillMessageTool)

    parent = self()

    llm_client = fn _messages, opts ->
      send(parent, {:tools, Keyword.get(opts, :tools, [])})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    assert {:ok, "ok", _session} =
             Runner.run(Session.new("tool-dedupe"), "show available tools",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true
             )

    assert_receive {:tools, tools}

    names = Enum.map(tools, & &1["name"])

    assert "skill_discover" in names
    assert "skill_get" in names
    assert "skill_capture" in names
    refute "skill_list" in names
    refute "skill_read" in names
    refute "skill_create" in names
    refute Enum.any?(names, &String.starts_with?(&1, "feishu_"))
    assert Enum.count(names, fn name -> name == "skill_message" end) == 1
    refute "skill_code-review" in names
  end

  test "subagent tool surface excludes outward communication and recursive scheduling" do
    names =
      Registry.definitions(:subagent)
      |> Enum.map(& &1["name"])

    assert "read" in names
    assert "find" in names
    assert "apply_patch" in names
    assert "executor_dispatch" in names
    assert "executor_status" in names
    assert "skill_discover" in names
    assert "skill_get" in names
    assert "reflect" in names
    refute "evolution_candidate" in names
    refute "skill_list" in names
    refute "skill_read" in names
    refute "skill_create" in names
    refute Enum.any?(names, &String.starts_with?(&1, "feishu_"))

    refute "message" in names
    refute "cron" in names
    refute "task" in names
    refute "spawn_task" in names
    refute "knowledge_capture" in names
    refute "memory_consolidate" in names
    refute "memory_write" in names
    refute "edit" in names
    refute "write" in names
    refute "list_dir" in names
    refute "self_update" in names

    reflect = Enum.find(Registry.definitions(:subagent), &(&1["name"] == "reflect"))
    action_enum = get_in(reflect, ["input_schema", :properties, :action, :enum])

    assert "source" in action_enum
    assert "versions" in action_enum
    assert "introspect" in action_enum
    assert "list_modules" in action_enum
  end

  test "follow-up tool surface keeps read-only discovery path without patch mutation" do
    names =
      Registry.definitions(:follow_up)
      |> Enum.map(& &1["name"])

    assert "read" in names
    assert "find" in names
    assert "observe" in names
    assert Enum.count(names, &(&1 == "web_search")) == 1
    refute "apply_patch" in names
    refute "evolution_candidate" in names
  end

  test "web_search stays a single function tool name on official codex backend" do
    config =
      %Nex.Agent.Config{
        Nex.Agent.Config.default()
        | tools: %{
            "web_search" => %{
              "provider" => "codex",
              "providers" => %{"codex" => %{"mode" => "live"}}
            }
          }
      }

    definitions =
      Registry.definitions(:follow_up,
        config: config,
        provider: :openai_codex,
        base_url: "https://chatgpt.com/backend-api/codex"
      )

    assert Enum.count(definitions, &(&1["name"] == "web_search")) == 1

    assert Enum.any?(definitions, fn tool ->
             tool["name"] == "web_search" and is_map(tool["input_schema"])
           end)
  end

  test "image_generation is exposed as a single function tool on official codex backend" do
    config =
      %Nex.Agent.Config{
        Nex.Agent.Config.default()
        | tools: %{
            "image_generation" => %{
              "provider" => "codex",
              "providers" => %{"codex" => %{"output_format" => "png"}}
            }
          }
      }

    definitions =
      Registry.definitions(:all,
        config: config,
        provider: :openai_codex,
        base_url: "https://chatgpt.com/backend-api/codex"
      )

    assert Enum.count(definitions, &(&1["name"] == "image_generation")) == 1

    assert Enum.any?(definitions, fn tool ->
             tool["name"] == "image_generation" and is_map(tool["input_schema"])
           end)
  end

  test "runner keeps web_search as a function tool under provider overrides", %{
    workspace: workspace
  } do
    codex_config =
      %Nex.Agent.Config{
        Nex.Agent.Config.default()
        | tools: %{
            "web_search" => %{
              "provider" => "codex",
              "providers" => %{"codex" => %{"mode" => "live"}}
            }
          }
      }

    snapshot = %Snapshot{
      version: 1,
      workspace: workspace,
      config: codex_config,
      prompt: %{system_prompt: "", diagnostics: [], hash: "test"},
      commands: %{definitions: [], hash: "test"},
      skills: %{always_instructions: "", hash: "test"},
      changed_paths: [],
      channels: %{},
      tools: %{
        definitions_all:
          Registry.definitions(:all,
            config: codex_config,
            provider: :openai_codex,
            base_url: "https://chatgpt.com/backend-api/codex"
          ),
        definitions_follow_up: [],
        definitions_subagent: [],
        definitions_cron: [],
        hash: "test"
      }
    }

    parent = self()

    llm_client = fn _messages, opts ->
      send(parent, {:tools, Keyword.get(opts, :tools, [])})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    assert {:ok, "ok", _session} =
             Runner.run(Session.new("provider-override"), "search for docs",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               runtime_snapshot: snapshot,
               provider: :anthropic,
               skip_consolidation: true
             )

    assert_receive {:tools, tools}

    web_search = Enum.find(tools, &(&1["name"] == "web_search"))

    assert is_map(web_search["input_schema"])
    refute web_search["type"] == "web_search"
  end

  test "evolution_candidate tool stays owner-only on the all surface" do
    all_names = Registry.definitions(:all) |> Enum.map(& &1["name"])

    assert "evolution_candidate" in all_names

    definition = EvolutionCandidate.definition()

    assert get_in(definition, [:parameters, :properties, :action, :enum]) == [
             "list",
             "show",
             "approve",
             "reject"
           ]
  end

  test "memory tool descriptions clearly separate consolidate status and rebuild intents" do
    definitions = Registry.definitions(:all)

    tools =
      definitions
      |> Map.new(&{&1["name"], &1})

    names = Enum.map(definitions, & &1["name"])

    assert tools["memory_consolidate"]["description"] =~ "trigger memory consolidation"
    assert tools["memory_consolidate"]["description"] =~ "触发记忆整理"
    assert tools["memory_status"]["description"] =~ "check memory status"
    assert tools["memory_status"]["description"] =~ "检查记忆状态"
    assert tools["memory_rebuild"]["description"] =~ "full rebuild"
    assert tools["memory_rebuild"]["description"] =~ "重建记忆"

    assert Enum.find_index(names, &(&1 == "memory_consolidate")) <
             Enum.find_index(names, &(&1 == "memory_status"))

    assert Enum.find_index(names, &(&1 == "memory_status")) <
             Enum.find_index(names, &(&1 == "memory_rebuild"))
  end

  test "runner keeps raw slash-prefixed prompts and does not persist mode metadata", %{
    workspace: workspace
  } do
    parent = self()

    llm_client = fn messages, _opts ->
      send(parent, {:messages, messages})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    assert {:ok, "ok", session} =
             Runner.run(Session.new("raw-prefix"), "/code keep this literal",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               cwd: workspace,
               skip_consolidation: true
             )

    assert_receive {:messages, messages}
    user_message = List.last(messages)

    assert user_message["role"] == "user"
    assert user_message["content"] =~ "/code keep this literal"

    persisted_user =
      Enum.find(session.messages, fn message ->
        message["role"] == "user"
      end)

    assert persisted_user["content"] == "/code keep this literal"
    refute Map.has_key?(persisted_user, "intent")
    refute Map.has_key?(persisted_user, "secondary_intents")
    refute Map.has_key?(persisted_user, "explicit_mode")
    refute Map.has_key?(persisted_user, "raw_prompt")
  end

  test "runtime skill tools follow the current turn workspace", %{
    workspace: workspace
  } do
    other_workspace =
      Path.join(System.tmp_dir!(), "nex-agent-skill-tool-#{System.unique_integer([:positive])}")

    assert {:ok, _package} =
             SkillRuntime.capture(
               %{
                 "name" => "global-only",
                 "description" => "Only available in the app workspace.",
                 "content" => "This package only lives in the app workspace."
               },
               workspace: workspace,
               project_root: workspace,
               skill_runtime: %{"enabled" => true}
             )

    assert {:ok, package} =
             SkillRuntime.capture(
               %{
                 "name" => "ops.v2",
                 "description" => "Only available in the turn workspace.",
                 "content" => "Use the v2 operations checklist."
               },
               workspace: other_workspace,
               project_root: other_workspace,
               skill_runtime: %{"enabled" => true}
             )

    on_exit(fn -> File.rm_rf!(other_workspace) end)

    assert {:ok, result} =
             SkillDiscover.execute(
               %{"query" => "operations checklist", "scope" => "local"},
               %{
                 workspace: other_workspace,
                 cwd: other_workspace,
                 skill_runtime: %{"enabled" => true}
               }
             )

    hits = result["hits"]
    assert Enum.any?(hits, &(&1["name"] == "ops.v2"))
    refute Enum.any?(hits, &(&1["name"] == "global-only"))

    assert {:ok, loaded} =
             SkillGet.execute(
               %{"skill_id" => package.skill_id},
               %{
                 workspace: other_workspace,
                 cwd: other_workspace,
                 skill_runtime: %{"enabled" => true}
               }
             )

    assert loaded["progressive_disclosure"]["content"] =~ "Use the v2 operations checklist."
  end

  test "agent prompt passes session key into runner tool context", %{workspace: workspace} do
    llm_client = fn messages, _opts ->
      tool_result_present =
        Enum.any?(messages, fn
          %{"role" => "tool", "name" => "memory_status", "content" => content} ->
            String.contains?(content, "\"session_key\"")

          _ ->
            false
        end)

      if tool_result_present do
        tool_result =
          Enum.find(messages, fn
            %{"role" => "tool", "name" => "memory_status"} -> true
            _ -> false
          end)

        {:ok, %{content: tool_result["content"], finish_reason: nil, tool_calls: []}}
      else
        {:ok,
         %{
           content: "",
           finish_reason: nil,
           tool_calls: [
             %{
               id: "memory_status",
               function: %{
                 name: "memory_status",
                 arguments: %{}
               }
             }
           ]
         }}
      end
    end

    {:ok, agent} =
      Nex.Agent.start(
        workspace: workspace,
        channel: "feishu",
        chat_id: "session-key-check",
        api_key: "test-api-key"
      )

    assert {:ok, result, _updated_agent} =
             Nex.Agent.prompt(agent, "检查记忆状态",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true,
               channel: "feishu",
               chat_id: "session-key-check"
             )

    decoded = Jason.decode!(result)
    assert decoded["session_key"] == "feishu:session-key-check"
  end

  defp wait_for_registry_tool(name, module, attempts \\ 20)

  defp wait_for_registry_tool(_name, _module, 0),
    do: flunk("registry tool did not register in time")

  defp wait_for_registry_tool(name, module, attempts) do
    case Registry.get(name) do
      ^module ->
        :ok

      _ ->
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
  end

  defp render_mock_content(nil), do: ""
  defp render_mock_content(text) when is_binary(text), do: text
  defp render_mock_content(text), do: inspect(text, printable_limit: 500, limit: 50)
end
