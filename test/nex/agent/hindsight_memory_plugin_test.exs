defmodule Nex.Agent.HindsightMemoryPluginTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Capability.Hooks
  alias Nex.Agent.Capability.Tool.Registry
  alias Nex.Agent.Interface.MCP.ServerManager
  alias Nex.Agent.Runtime
  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Sandbox.Approval
  alias Nex.Agent.Tasks.Runner, as: TaskRunner

  @plugin_id "builtin:memory.hindsight"
  @mcp_id "hindsight"
  @server_id ServerManager.plugin_server_id(@plugin_id, @mcp_id)

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-hindsight-plugin-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "IDENTITY.md"), "# Identity\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")

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

  test "hindsight builtin plugin is installed but disabled by default", %{workspace: workspace} do
    config = Config.from_map(Config.default_map())

    assert {:ok, snapshot} = reload_runtime(workspace, config)

    assert Enum.any?(snapshot.plugins.manifests, &(&1["id"] == @plugin_id))
    refute @server_id in snapshot.plugins.active_mcp_servers
    refute Enum.any?(snapshot.tools.definitions_all, &(&1["name"] == "hindsight__recall"))
    assert File.exists?(Path.join(workspace, "memory/hindsight/status.json")) == false
  end

  test "enabled hindsight plugin wires recall hook and retain task through HTTP MCP", %{
    workspace: workspace
  } do
    parent = self()
    install_hindsight_http(parent)
    config = enabled_config()

    assert {:ok, snapshot} = reload_runtime(workspace, config)

    assert @server_id in snapshot.plugins.active_mcp_servers
    assert File.exists?(Path.join(workspace, "memory/hindsight/status.json"))
    assert File.dir?(Path.join(workspace, "memory/hindsight/exports"))

    assert_receive {:hindsight_http, %{method: "initialize", headers: init_headers}}
    assert http_header_value(init_headers, "authorization") == "Bearer hindsight-test-token"
    assert http_header_value(init_headers, "x-bank-id") == "nex-test-bank"

    definitions = Registry.definitions(:all, plugin_data: snapshot.plugins, config: config)
    assert Enum.any?(definitions, &(&1["name"] == "hindsight__recall"))
    assert Enum.any?(definitions, &(&1["name"] == "hindsight__retain"))
    assert Enum.any?(definitions, &(&1["name"] == "hindsight__mental_model"))
    assert Enum.any?(definitions, &(&1["name"] == "hindsight__operation_status"))

    hooks = Hooks.load(workspace: workspace, plugin_data: snapshot.plugins)

    ctx = %{
      workspace: workspace,
      config: config,
      runtime_snapshot: snapshot,
      plugin_data: snapshot.plugins,
      session_key: "discord:hindsight",
      channel: "discord",
      chat_id: "hindsight",
      turn_prompt: "what should you remember about my architecture preference?"
    }

    assert {:ok, [fragment]} = Hooks.run(:prompt_build_before, hooks, ctx)

    assert_receive {:hindsight_http,
                    %{method: "tools/call", tool: "recall", arguments: recall_args}}

    assert recall_args["query"] == ctx.turn_prompt
    assert recall_args["budget"] == "mid"
    assert fragment["title"] == "Hindsight Memory"
    assert fragment["content"] =~ "remembered architecture preference"

    assert {:ok, []} = Hooks.run(:conversation_turn_finished, hooks, ctx)

    assert eventually(fn ->
             retain_calls = http_tool_calls("retain")

             length(retain_calls) == 1 and
               List.first(retain_calls).arguments["content"] == ctx.turn_prompt and
               get_in(List.first(retain_calls).arguments, ["metadata", "session_key"]) ==
                 "discord:hindsight"
           end)
  end

  defp enabled_config do
    Config.from_map(%{
      Config.default_map()
      | "plugins" => %{
          "enabled" => %{@plugin_id => true},
          "config" => %{
            @plugin_id => %{
              "mcp_url" => "https://hindsight.example.test/mcp/",
              "bank_id" => "nex-test-bank",
              "authorization_header" => "Bearer hindsight-test-token"
            }
          }
        },
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

  defp install_hindsight_http(parent) do
    Application.put_env(:nex_agent, :http_test_req_post, fn url, opts ->
      request = Keyword.fetch!(opts, :json)
      headers = Keyword.fetch!(opts, :headers)
      method = http_request_method(request)
      event = %{url: url, request: request, headers: headers, method: method}

      case method do
        "initialize" ->
          send(parent, {:hindsight_http, event})

          http_json_response(request, %{"capabilities" => %{}},
            headers: [
              {"content-type", "application/json"},
              {"MCP-Session-Id", "hindsight-session"}
            ]
          )

        "notifications/initialized" ->
          send(parent, {:hindsight_http, event})
          {:ok, %{status: 202, headers: [], body: ""}}

        "tools/call" ->
          params = http_request_params(request)
          tool = params["name"] || params[:name]
          arguments = params["arguments"] || params[:arguments] || %{}
          send(parent, {:hindsight_http, Map.merge(event, %{tool: tool, arguments: arguments})})

          result =
            case tool do
              "recall" ->
                %{"memories" => ["remembered architecture preference"]}

              "retain" ->
                %{"retained" => true, "operation_id" => "op-test"}

              "get_mental_model" ->
                %{"mental_model_id" => arguments["mental_model_id"], "content" => "model"}

              "get_operation" ->
                %{"operation_id" => arguments["operation_id"], "status" => "completed"}
            end

          http_json_response(request, result)
      end
    end)
  end

  defp http_tool_calls(tool) do
    {:messages, messages} = Process.info(self(), :messages)

    messages
    |> Enum.flat_map(fn
      {:hindsight_http, %{method: "tools/call", tool: ^tool, arguments: arguments}} ->
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

  defp eventually(fun, attempts \\ 60)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:nex_agent, key)
  defp restore_app_env(key, value), do: Application.put_env(:nex_agent, key, value)
end
