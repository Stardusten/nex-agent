defmodule Nex.Agent.PluginExternalServiceFoundationTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Capability.Hooks
  alias Nex.Agent.Capability.Tool.Registry
  alias Nex.Agent.Interface.MCP.ServerManager
  alias Nex.Agent.Observe.ControlPlane.Query
  alias Nex.Agent.Runtime
  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Sandbox.{Approval, PermissionRuleStore}
  alias Nex.Agent.Tasks.Runner, as: TaskRunner

  @plugin_id "workspace:fake-memory"
  @mcp_id "fake_memory_mcp"
  @server_id ServerManager.plugin_server_id(@plugin_id, @mcp_id)
  @endpoint "https://fake-memory.example.test/mcp"

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-plugin-external-service-#{System.unique_integer([:positive])}"
      )

    plugin_root = Path.join(workspace, "plugins/fake-memory")
    File.mkdir_p!(plugin_root)
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "IDENTITY.md"), "# Identity\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(plugin_root, "nex.plugin.json"), Jason.encode!(fake_memory_manifest()))

    previous_workspace = Application.get_env(:nex_agent, :workspace_path)
    previous_config_path = Application.get_env(:nex_agent, :config_path)
    previous_post = Application.get_env(:nex_agent, :http_test_req_post)

    Application.put_env(:nex_agent, :workspace_path, workspace)
    Application.put_env(:nex_agent, :config_path, Path.join(workspace, "config.json"))

    for {mod, name} <- [
          {Task.Supervisor, Nex.Agent.TaskSupervisor},
          {Registry, Registry},
          {TaskRunner, TaskRunner},
          {Approval, Approval},
          {ServerManager, ServerManager},
          {Runtime, Runtime}
        ] do
      if Process.whereis(name) == nil do
        start_supervised!({mod, name: name})
      end
    end

    _ = ServerManager.stop(@server_id)

    on_exit(fn ->
      _ = ServerManager.stop(@server_id)
      restore_app_env(:workspace_path, previous_workspace)
      restore_app_env(:config_path, previous_config_path)
      restore_app_env(:http_test_req_post, previous_post)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "fake external memory plugin closes recall/retain loop with direct config header", %{
    workspace: workspace
  } do
    parent = self()
    install_fake_memory_http(parent)
    config = enabled_config()

    assert {:ok, snapshot} = reload_runtime(workspace, config)

    assert @server_id in snapshot.plugins.active_mcp_servers
    assert File.exists?(Path.join(workspace, "plugin_data/fake_memory/cache.json"))
    assert File.exists?(Path.join(workspace, "plugin_data/fake_memory/status.json"))

    assert_receive {:fake_memory_http, %{method: "initialize", headers: init_headers}}
    assert http_header_value(init_headers, "authorization") == "Bearer fake-memory-token"
    assert http_header_value(init_headers, "x-memory-bank") == expected_bank(workspace, nil)
    assert_receive {:fake_memory_http, %{method: "notifications/initialized"}}

    definitions = Registry.definitions(:all, plugin_data: snapshot.plugins, config: config)
    assert Enum.any?(definitions, &(&1["name"] == "fake_memory__recall"))
    assert Enum.any?(definitions, &(&1["name"] == "fake_memory__retain"))

    hooks = Hooks.load(workspace: workspace, plugin_data: snapshot.plugins)

    ctx =
      hook_context(workspace, config, snapshot,
        session_key: "discord:fake",
        turn_prompt: "where did I park?"
      )

    assert {:ok, [fragment]} = Hooks.run(:prompt_build_before, hooks, ctx)

    assert_receive {:fake_memory_http,
                    %{method: "tools/call", tool: "recall", arguments: recall_args}}

    assert recall_args["query"] == "where did I park?"
    assert recall_args["bank"] == expected_bank(workspace, "discord:fake")

    assert {:ok, []} =
             Hooks.run(
               :conversation_turn_finished,
               hooks,
               %{ctx | turn_prompt: "retain stale prompt"}
             )

    assert {:ok, []} =
             Hooks.run(
               :conversation_turn_finished,
               hooks,
               %{ctx | turn_prompt: "retain final prompt"}
             )

    assert eventually(fn ->
             retain_calls = http_tool_calls("retain")

             length(retain_calls) == 1 and
               List.first(retain_calls).arguments["input"] == "retain final prompt" and
               List.first(retain_calls).arguments["bank"] ==
                 expected_bank(workspace, "discord:fake")
           end)

    assert fragment["kind"] == "tool_result"
    assert fragment["content"] =~ "remembered:where did I park?"
    assert fragment["content"] =~ expected_bank(workspace, "discord:fake")

    observations = Query.query(%{"limit" => 100}, workspace: workspace)
    assert Enum.any?(observations, &(&1["tag"] == "plugin.task.debounced"))
    assert Enum.any?(observations, &(&1["tag"] == "plugin.task.finished"))
  end

  test "disabled fake external memory plugin contributes no executable tools", %{
    workspace: workspace
  } do
    parent = self()
    install_fake_memory_http(parent)
    config = disabled_config()

    assert {:ok, snapshot} = reload_runtime(workspace, config)

    refute @server_id in snapshot.plugins.active_mcp_servers
    refute Enum.any?(snapshot.tools.definitions_all, &(&1["name"] == "fake_memory__recall"))
    refute Enum.any?(snapshot.tools.definitions_all, &(&1["name"] == "fake_memory__retain"))

    assert {:error, message} =
             Registry.execute("fake_memory__recall", %{}, %{
               workspace: workspace,
               runtime_snapshot: snapshot,
               config: config
             })

    assert message =~ "Unknown tool: fake_memory__recall"
    refute_received {:fake_memory_http, _event}
  end

  test "permission deny blocks fake external memory MCP connection", %{workspace: workspace} do
    parent = self()
    install_fake_memory_http(parent)

    deny_rule = %{
      id: "deny-fake-memory-mcp-connect",
      effect: :deny,
      scope: :workspace,
      predicates: [
        {:resource_eq, :mcp},
        {:operation_in, [:connect]},
        {:eq, :mcp_server, @mcp_id}
      ]
    }

    assert :ok = PermissionRuleStore.save(workspace, [deny_rule])
    restart_approval()

    config = enabled_config()
    assert {:ok, snapshot} = reload_runtime(workspace, config)

    refute @server_id in snapshot.plugins.active_mcp_servers
    refute Enum.any?(snapshot.tools.definitions_all, &(&1["name"] == "fake_memory__recall"))
    refute_received {:fake_memory_http, _event}
  end

  test "empty direct config authorization header is omitted", %{
    workspace: workspace
  } do
    parent = self()
    install_fake_memory_http(parent)
    config = enabled_config(%{"authorization_header" => ""})

    assert {:ok, snapshot} = reload_runtime(workspace, config)

    assert @server_id in snapshot.plugins.active_mcp_servers
    assert_receive {:fake_memory_http, %{method: "initialize", headers: init_headers}}
    refute http_header_value(init_headers, "authorization")
  end

  defp fake_memory_manifest do
    %{
      "id" => @plugin_id,
      "title" => "Fake External Memory",
      "source" => "workspace",
      "contributes" => %{
        "tools" => [
          %{
            "name" => "fake_memory__recall",
            "from" => "mcp:#{@mcp_id}/recall",
            "description" => "Recall relevant memories from a fake external service.",
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "query" => %{"type" => "string"},
                "bank" => %{"type" => "string"}
              },
              "required" => ["query", "bank"]
            }
          },
          %{
            "name" => "fake_memory__retain",
            "from" => "mcp:#{@mcp_id}/retain",
            "description" => "Retain turn facts into a fake external service.",
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "input" => %{"type" => "string"},
                "bank" => %{"type" => "string"}
              },
              "required" => ["input", "bank"]
            }
          }
        ],
        "hooks" => [
          %{
            "id" => "fake_memory.recall_before_prompt",
            "event" => "prompt.build.before",
            "action" => %{
              "type" => "add_tool_result",
              "tool" => "fake_memory__recall",
              "args" => %{
                "query" => "{{turn.prompt}}",
                "bank" => "{{plugin.config.bank_template}}"
              },
              "title" => "Fake Memory Recall",
              "onError" => "block"
            }
          },
          %{
            "id" => "fake_memory.retain_after_turn",
            "event" => "conversation.turn.finished",
            "action" => %{
              "type" => "enqueue_task",
              "task" => "fake_memory.retain",
              "onError" => "warn"
            }
          }
        ],
        "tasks" => [
          %{
            "id" => "fake_memory.retain",
            "policy" => %{
              "debounce_key" => "retain:{{plugin.id}}:{{session.key}}",
              "debounce_ms" => 40,
              "max_runs" => 1
            },
            "action" => %{
              "type" => "tool_call",
              "tool" => "fake_memory__retain",
              "args" => %{
                "input" => "{{turn.prompt}}",
                "bank" => "{{plugin.config.bank_template}}"
              }
            }
          }
        ],
        "workspaceFiles" => [
          %{
            "id" => "fake_memory.cache",
            "path" => "plugin_data/fake_memory/cache.json",
            "kind" => "file",
            "onMissing" => "create"
          },
          %{
            "id" => "fake_memory.status",
            "path" => "plugin_data/fake_memory/status.json",
            "kind" => "file",
            "onMissing" => "create"
          }
        ],
        "mcpServers" => [
          %{
            "id" => @mcp_id,
            "transport" => "streamable-http",
            "url" => "{{plugin.config.endpoint}}",
            "headers" => %{
              "Authorization" => "{{plugin.config.authorization_header}}",
              "X-Memory-Bank" => "{{plugin.config.bank_template}}"
            },
            "tool_timeout" => 1
          }
        ]
      }
    }
  end

  defp enabled_config(overrides \\ %{}) do
    config(%{
      "disabled" => [],
      "enabled" => %{@plugin_id => true},
      "config" => %{
        @plugin_id =>
          Map.merge(
            %{
              "endpoint" => @endpoint,
              "bank_template" => "bank:{{workspace.hash}}:{{session.key}}",
              "authorization_header" => "Bearer fake-memory-token"
            },
            overrides
          )
      }
    })
  end

  defp disabled_config do
    config(%{
      "disabled" => [@plugin_id],
      "enabled" => %{@plugin_id => true},
      "config" => %{
        @plugin_id => %{
          "endpoint" => @endpoint,
          "bank_template" => "bank:{{workspace.hash}}:{{session.key}}",
          "authorization_header" => "Bearer fake-memory-token"
        }
      }
    })
  end

  defp config(plugins) do
    Config.from_map(%{
      Config.default_map()
      | "plugins" => plugins,
        "tools" => %{
          "sandbox" => %{
            "backend" => "noop",
            "approval" => %{"default" => "allow"}
          }
        }
    })
  end

  defp reload_runtime(workspace, config) do
    result = Runtime.reload(workspace: workspace, config_loader: fn _opts -> config end)
    Registry.reload()
    result
  end

  defp hook_context(workspace, config, snapshot, opts) do
    %{
      workspace: workspace,
      config: config,
      runtime_snapshot: snapshot,
      plugin_data: snapshot.plugins,
      session_key: Keyword.fetch!(opts, :session_key),
      channel: "discord",
      chat_id: "fake-memory",
      turn_prompt: Keyword.fetch!(opts, :turn_prompt)
    }
  end

  defp install_fake_memory_http(parent) do
    Application.put_env(:nex_agent, :http_test_req_post, fn url, opts ->
      request = Keyword.fetch!(opts, :json)
      headers = Keyword.fetch!(opts, :headers)
      method = http_request_method(request)
      event = %{url: url, request: request, headers: headers, method: method}

      case method do
        "initialize" ->
          send(parent, {:fake_memory_http, event})

          http_json_response(request, %{"capabilities" => %{}},
            headers: [{"content-type", "application/json"}, {"MCP-Session-Id", "fake-session"}]
          )

        "notifications/initialized" ->
          send(parent, {:fake_memory_http, event})
          {:ok, %{status: 202, headers: [], body: ""}}

        "tools/list" ->
          send(parent, {:fake_memory_http, event})

          http_json_response(request, %{
            "tools" => [
              %{"name" => "recall", "description" => "Recall"},
              %{"name" => "retain", "description" => "Retain"}
            ]
          })

        "tools/call" ->
          params = http_request_params(request)
          tool = params["name"] || params[:name]
          arguments = params["arguments"] || params[:arguments] || %{}
          send(parent, {:fake_memory_http, Map.merge(event, %{tool: tool, arguments: arguments})})

          result =
            case tool do
              "recall" ->
                %{
                  "memories" => ["remembered:#{arguments["query"]}"],
                  "bank" => arguments["bank"]
                }

              "retain" ->
                %{
                  "retained" => true,
                  "input" => arguments["input"],
                  "bank" => arguments["bank"]
                }
            end

          http_json_response(request, result)
      end
    end)
  end

  defp http_tool_calls(tool) do
    {:messages, messages} = Process.info(self(), :messages)

    messages
    |> Enum.flat_map(fn
      {:fake_memory_http, %{method: "tools/call", tool: ^tool, arguments: arguments}} ->
        [%{tool: tool, arguments: arguments}]

      _ ->
        []
    end)
  end

  defp http_json_response(request, result, opts \\ []) do
    {:ok,
     %{
       status: 200,
       headers: Keyword.get(opts, :headers, [{"content-type", "application/json"}]),
       body: %{"jsonrpc" => "2.0", "id" => http_request_id(request), "result" => result}
     }}
  end

  defp http_request_method(%{method: method}), do: method
  defp http_request_method(%{"method" => method}), do: method

  defp http_request_id(%{id: id}), do: id
  defp http_request_id(%{"id" => id}), do: id

  defp http_request_params(%{params: params}), do: params
  defp http_request_params(%{"params" => params}), do: params

  defp http_header_value(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp expected_bank(workspace, session_key) do
    "bank:#{workspace_hash(workspace)}:#{session_key}"
  end

  defp workspace_hash(root) do
    :crypto.hash(:sha256, root)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp restart_approval do
    if pid = Process.whereis(Approval) do
      GenServer.stop(pid, :normal)
    end

    unless eventually(fn -> Process.whereis(Approval) != nil end) do
      {:ok, _pid} = Approval.start_link(name: Approval)
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:nex_agent, key)
  defp restore_app_env(key, value), do: Application.put_env(:nex_agent, key, value)
end
