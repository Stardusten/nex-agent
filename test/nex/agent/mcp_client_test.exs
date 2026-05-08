defmodule Nex.Agent.MCPClientTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Interface.MCP
  alias Nex.Agent.Interface.MCP.ServerManager
  alias Nex.Agent.Runtime.Config

  setup do
    config =
      Config.from_map(%{
        "tools" => %{
          "sandbox" => %{
            "backend" => "noop",
            "approval" => %{"default" => "allow"}
          }
        }
      })

    %{config: config, workspace: File.cwd!()}
  end

  test "stdio transport preserves MCP JSON-RPC lifecycle", %{config: config, workspace: workspace} do
    script = """
    while IFS= read -r line; do
      case "$line" in
        *\"initialize\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{},"serverInfo":{"name":"fake"}}}'
          ;;
        *\"tools/list\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo"}]}}'
          ;;
        *\"tools/call\"*)
          printf '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"%s"}]}}\n' "${NEX_ECHO:-missing}"
          ;;
      esac
    done
    """

    {:ok, pid} =
      MCP.start_link(
        transport: "stdio",
        command: "sh",
        args: ["-c", script],
        env: [NEX_ECHO: "pong"],
        config: config,
        cwd: workspace,
        workspace: workspace
      )

    assert :ok = MCP.initialize(pid)
    assert {:ok, %{"tools" => [%{"name" => "echo"}]}} = MCP.list_tools(pid)

    assert {:ok, %{"content" => [%{"text" => "pong"}]}} =
             MCP.call_tool(pid, "echo", %{"text" => "ping"})

    assert :ok = MCP.stop(pid)
  end

  test "protocol methods reject tool operations before initialize", %{
    config: config,
    workspace: workspace
  } do
    script = "while IFS= read -r _line; do :; done"

    {:ok, pid} =
      MCP.start_link(
        transport: "stdio",
        command: "sh",
        args: ["-c", script],
        config: config,
        cwd: workspace,
        workspace: workspace
      )

    assert {:error, :not_initialized} = MCP.list_tools(pid)
    assert {:error, :not_initialized} = MCP.call_tool(pid, "echo", %{})
    assert :ok = MCP.stop(pid)
  end

  test "unsupported transports fail at the client boundary" do
    assert {:error, {:unsupported_transport, "websocket"}} =
             MCP.start_link(%{"transport" => "websocket", "url" => "http://127.0.0.1/mcp"})
  end

  test "transport is explicit instead of defaulting to stdio" do
    assert {:error, :transport_required} =
             MCP.start_link(%{"command" => "sh", "args" => ["-c", "exit 0"]})
  end

  test "server manager starts configured servers without self-calling its GenServer", %{
    config: config,
    workspace: workspace
  } do
    unless Process.whereis(ServerManager) do
      start_supervised!({ServerManager, name: ServerManager})
    end

    previous = Application.get_env(:nex_agent, :mcp_servers)

    script = """
    while IFS= read -r line; do
      case "$line" in
        *\"initialize\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}'
          ;;
      esac
    done
    """

    Application.put_env(:nex_agent, :mcp_servers, %{
      "configured_echo" => [
        transport: "stdio",
        command: "sh",
        args: ["-c", script],
        config: config,
        cwd: workspace,
        workspace: workspace
      ]
    })

    on_exit(fn ->
      if previous do
        Application.put_env(:nex_agent, :mcp_servers, previous)
      else
        Application.delete_env(:nex_agent, :mcp_servers)
      end
    end)

    assert {:ok, [server_id]} = ServerManager.start_configured()
    assert String.starts_with?(server_id, "configured_echo-")
    assert :ok = ServerManager.stop(server_id)
  end

  test "server manager accepts string-keyed transport config without atomizing it", %{
    config: config,
    workspace: workspace
  } do
    unless Process.whereis(ServerManager) do
      start_supervised!({ServerManager, name: ServerManager})
    end

    server_id = "string-keyed-#{System.unique_integer([:positive])}"

    script = """
    while IFS= read -r line; do
      case "$line" in
        *\"initialize\"*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}'
          ;;
      esac
    done
    """

    assert {:ok, ^server_id} =
             ServerManager.start(
               "string_keyed",
               %{
                 "transport" => "stdio",
                 "command" => "sh",
                 "args" => ["-c", script],
                 "config" => config,
                 "cwd" => workspace,
                 "workspace" => workspace,
                 "tool_timeout" => 7
               },
               server_id: server_id
             )

    assert %{tool_timeout: 7, config: %{"transport" => "stdio"}} =
             ServerManager.list() |> Enum.find(&(&1.id == server_id))

    assert :ok = ServerManager.stop(server_id)
  end
end
