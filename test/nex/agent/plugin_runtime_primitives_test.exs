defmodule Nex.Agent.Test.PluginEchoTool do
  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Sandbox.FileSystem

  def name, do: "echo__remember"
  def description, do: "Remember prompt text into plugin state."
  def category, do: :tool

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{"source" => %{type: "string"}},
        required: ["source"]
      }
    }
  end

  def execute(%{"source" => source}, ctx) do
    workspace = Map.get(ctx, :workspace) || File.cwd!()
    path = Path.join(workspace, "plugin_data/echo/state.json")
    content = Jason.encode!(%{"last" => source})

    case FileSystem.write_file(path, content, ctx) do
      :ok -> {:ok, %{"status" => "written", "path" => path}}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_args, _ctx), do: {:error, "source is required"}
end

defmodule Nex.Agent.PluginRuntimePrimitivesTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Capability.Hooks, Runtime, Runtime.Config}
  alias Nex.Agent.Capability.Tool.Registry
  alias Nex.Agent.Conversation.Session
  alias Nex.Agent.Interface.MCP.ServerManager
  alias Nex.Agent.Runtime.PluginJobRunner
  alias Nex.Agent.Turn.Runner

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-plugin-primitives-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "plugins/demo-echo"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "IDENTITY.md"), "# Identity\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")

    script = """
    while IFS= read -r line; do
      case "$line" in
        *\\"initialize\\"*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{},"tools":[]}}'
          ;;
        *\\"tools/call\\"*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"echo":"pong"}}'
          ;;
      esac
    done
    """

    File.write!(
      Path.join(workspace, "plugins/demo-echo/nex.plugin.json"),
      Jason.encode!(%{
        "id" => "workspace:demo-echo",
        "title" => "Demo Echo",
        "source" => "workspace",
        "contributes" => %{
          "tools" => [
            %{
              "name" => "echo__remember",
              "from" => "module:Nex.Agent.Test.PluginEchoTool",
              "description" => "Remember prompt text into plugin state.",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"source" => %{"type" => "string"}}
              }
            },
            %{
              "name" => "echo__remote",
              "from" => "mcp:echo_mcp/echo",
              "description" => "Remote MCP echo.",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"text" => %{"type" => "string"}}
              }
            }
          ],
          "hooks" => [
            %{
              "id" => "echo.prompt",
              "event" => "prompt.build.before",
              "action" => %{
                "type" => "add_file",
                "path" => "plugin_data/echo/state.json",
                "title" => "Echo State"
              }
            }
          ],
          "jobs" => [
            %{
              "id" => "echo.flush",
              "event" => "conversation.turn.finished",
              "action" => %{
                "type" => "tool_call",
                "tool" => "echo__remember",
                "args" => %{"source" => "{{turn.prompt}}"}
              }
            }
          ],
          "workspaceFiles" => [
            %{
              "id" => "echo.state",
              "path" => "plugin_data/echo/state.json",
              "kind" => "file",
              "onMissing" => "create",
              "watch" => true
            }
          ],
          "mcpServers" => [
            %{
              "id" => "echo_mcp",
              "command" => "sh",
              "args" => ["-c", script]
            }
          ]
        }
      })
    )

    config =
      Config.from_map(%{
        Config.default_map()
        | "plugins" => %{"enabled" => %{"workspace:demo-echo" => true}},
          "tools" => %{
            "sandbox" => %{
              "backend" => "noop",
              "approval" => %{"default" => "allow"}
            }
          }
      })

    previous_workspace = Application.get_env(:nex_agent, :workspace_path)
    previous_config_path = Application.get_env(:nex_agent, :config_path)
    Application.put_env(:nex_agent, :workspace_path, workspace)
    Application.put_env(:nex_agent, :config_path, Path.join(workspace, "config.json"))

    for {mod, name} <- [
          {Task.Supervisor, Nex.Agent.TaskSupervisor},
          {Registry, Registry},
          {PluginJobRunner, PluginJobRunner},
          {ServerManager, ServerManager},
          {Runtime, Runtime}
        ] do
      if Process.whereis(name) == nil do
        start_supervised!({mod, name: name})
      end
    end

    Runtime.reload(workspace: workspace, config_loader: fn _opts -> config end)
    Registry.reload()

    on_exit(fn ->
      if previous_workspace do
        Application.put_env(:nex_agent, :workspace_path, previous_workspace)
      else
        Application.delete_env(:nex_agent, :workspace_path)
      end

      if previous_config_path do
        Application.put_env(:nex_agent, :config_path, previous_config_path)
      else
        Application.delete_env(:nex_agent, :config_path)
      end

      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace, config: config}
  end

  test "runtime snapshot includes new plugin contribution kinds and initializes workspace file", %{
    workspace: workspace
  } do
    assert {:ok, snapshot} = Runtime.current()
    assert Enum.any?(snapshot.plugins.contributions.hooks, &(&1["id"] == "echo.prompt"))
    assert Enum.any?(snapshot.plugins.contributions.jobs, &(&1["id"] == "echo.flush"))
    assert Enum.any?(snapshot.plugins.contributions.workspace_files, &(&1["id"] == "echo.state"))
    assert Enum.any?(snapshot.plugins.contributions.mcp_servers, &(&1["id"] == "echo_mcp"))
    assert File.exists?(Path.join(workspace, "plugin_data/echo/state.json"))
  end

  test "plugin prompt hook injects declared workspace file", %{workspace: workspace} do
    File.write!(Path.join(workspace, "plugin_data/echo/state.json"), ~s({"seed":"hello"}))

    hooks =
      Hooks.load(
        workspace: workspace,
        plugin_data: Runtime.current() |> elem(1) |> Map.get(:plugins)
      )

    assert {:ok, [fragment]} =
             Hooks.run(:prompt_build_before, hooks, %{
               session_key: "discord:echo",
               workspace: workspace,
               turn_prompt: "ping"
             })

    assert fragment["content"] =~ "hello"
  end

  test "turn finished job reuses the plugin tool lane", %{workspace: workspace} do
    llm_client = fn _messages, _opts ->
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    assert {:ok, "ok", _session} =
             Runner.run(Session.new("discord:echo"), "remember me",
               llm_stream_client: stream_client_from_response(llm_client),
               runtime_snapshot: Runtime.current() |> elem(1),
               workspace: workspace,
               skip_consolidation: true,
               channel: "discord",
               chat_id: "echo"
             )

    assert eventually(fn ->
             File.read!(Path.join(workspace, "plugin_data/echo/state.json")) =~ "remember me"
           end)
  end

  test "public agent api runs plugin hook tool and follow-up job", %{workspace: workspace} do
    parent = self()
    File.write!(Path.join(workspace, "plugin_data/echo/state.json"), ~s({"seed":"public"}))
    Process.delete(:plugin_runtime_public_step)

    llm_client = fn messages, _opts ->
      send(parent, {:public_messages, messages})

      step = Process.get(:plugin_runtime_public_step, 0)
      Process.put(:plugin_runtime_public_step, step + 1)

      case step do
        0 ->
          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "call_echo_public",
                 function: %{
                   name: "echo__remember",
                   arguments: %{"source" => "remember public flow"}
                 }
               }
             ]
           }}

        _ ->
          {:ok, %{content: "done", finish_reason: nil, tool_calls: []}}
      end
    end

    {:ok, agent} =
      Nex.Agent.start(
        workspace: workspace,
        channel: "discord",
        chat_id: "public-flow",
        api_key: "test-api-key"
      )

    assert {:ok, "done", _updated_agent} =
             Nex.Agent.prompt(agent, "remember public flow",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               skip_consolidation: true,
               channel: "discord",
               chat_id: "public-flow"
             )

    assert_receive {:public_messages, messages}
    system = hd(messages)["content"]
    assert system =~ "Echo State"
    assert system =~ "public"

    assert eventually(fn ->
             File.read!(Path.join(workspace, "plugin_data/echo/state.json")) =~
               "remember public flow"
           end)
  end

  test "tool registry resolves module-backed and mcp-backed plugin tools", %{workspace: workspace, config: config} do
    definitions = Registry.definitions(:all, plugin_data: Runtime.current() |> elem(1) |> Map.get(:plugins), config: config)
    assert Enum.any?(definitions, &(&1["name"] == "echo__remember"))
    refute Enum.any?(definitions, &(&1["name"] == "echo__remote"))

    mcp_script = """
    while IFS= read -r line; do
      case "$line" in
        *\\"initialize\\"*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{},"tools":[]}}'
          ;;
        *\\"tools/call\\"*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"echo":"pong"}}'
          ;;
      esac
    done
    """

    assert {:ok, _} =
             ServerManager.start(
               "echo_mcp",
               [
                 command: "sh",
                 args: ["-c", mcp_script],
                 config: config,
                 cwd: workspace,
                 workspace: workspace
               ],
               server_id: ServerManager.plugin_server_id("workspace:demo-echo", "echo_mcp")
             )

    definitions = Registry.definitions(:all, plugin_data: Runtime.current() |> elem(1) |> Map.get(:plugins), config: config)
    assert Enum.any?(definitions, &(&1["name"] == "echo__remote"))

    assert {:ok, %{"status" => "written"}} =
             Registry.execute("echo__remember", %{"source" => "local"}, %{
               workspace: workspace,
               runtime_snapshot: Runtime.current() |> elem(1)
             })

    assert {:ok, %{"echo" => "pong"}} =
             Registry.execute("echo__remote", %{"text" => "ping"}, %{
               workspace: workspace,
               runtime_snapshot: Runtime.current() |> elem(1)
             })
  end

  defp stream_client_from_response(fun) when is_function(fun, 2) do
    fn messages, opts, callback ->
      case fun.(messages, opts) do
        {:ok, response} when is_map(response) ->
          content = Map.get(response, :content) || Map.get(response, "content") || ""
          if content != "", do: callback.({:delta, content})
          tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || []
          if tool_calls != [], do: callback.({:tool_calls, tool_calls})
          callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
          :ok

        other ->
          other
      end
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
end
