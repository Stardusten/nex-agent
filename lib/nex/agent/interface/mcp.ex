defmodule Nex.Agent.Interface.MCP do
  @moduledoc """
  MCP Client for connecting to Model Context Protocol servers.

  ## Usage

      # Start a connection
      {:ok, conn} = Nex.Agent.Interface.MCP.start_link(
        command: "mcp-server-filesystem",
        args: ["/Users/test/data"]
      )
      
      # Initialize
      :ok = Nex.Agent.Interface.MCP.initialize(conn)
      
      # List tools
      {:ok, tools} = Nex.Agent.Interface.MCP.list_tools(conn)
      
      # Call a tool
      {:ok, result} = Nex.Agent.Interface.MCP.call_tool(conn, "read_file", %{path: "/Users/test/data/file.txt"})
      
      # Stop
      Nex.Agent.Interface.MCP.stop(conn)
  """

  use GenServer
  require Logger

  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Sandbox.{Command, Exec, Policy}
  alias Nex.Agent.Sandbox.Process, as: SandboxProcess

  @timeout 30_000

  defstruct [
    :port,
    :sandbox_process,
    :request_id,
    :pending_requests,
    :tools,
    :initialized,
    :buffer
  ]

  # Client API

  @doc """
  Start a new MCP connection.

  ## Options

  * `:command` - Command to start the MCP server (required)
  * `:args` - Arguments for the command (default: [])
  * `:env` - Environment variables (default: %{})

  ## Examples

      {:ok, conn} = Nex.Agent.Interface.MCP.start_link(
        command: "mcp-server-filesystem",
        args: ["/Users/test/data"]
      )
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Initialize the MCP connection.
  """
  def initialize(pid, timeout \\ @timeout) do
    GenServer.call(pid, :initialize, timeout)
  end

  @doc """
  List available tools from the MCP server.
  """
  def list_tools(pid, timeout \\ @timeout) do
    GenServer.call(pid, :list_tools, timeout)
  end

  @doc """
  Call a tool on the MCP server.

  ## Parameters

  * `name` - Tool name
  * `arguments` - Tool arguments (map)

  ## Examples

      {:ok, result} = Nex.Agent.Interface.MCP.call_tool(conn, "read_file", %{path: "/tmp/test.txt"})
  """
  def call_tool(pid, name, arguments \\ %{}, timeout \\ @timeout) do
    GenServer.call(pid, {:call_tool, name, arguments}, timeout)
  end

  @doc """
  Stop the MCP connection.
  """
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, %{})
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    policy = sandbox_policy(opts, cwd)

    command = %Command{
      program: command,
      args: Enum.map(args, &to_string/1),
      cwd: cwd,
      env: Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end),
      timeout_ms: @timeout,
      metadata: %{
        workspace: Keyword.get(opts, :workspace, cwd),
        observe_context: %{
          workspace: Keyword.get(opts, :workspace, cwd)
        },
        observe_attrs: %{"interface" => "mcp"}
      }
    }

    case Exec.open(command, policy) do
      {:ok, %SandboxProcess{} = process} ->
        state = %__MODULE__{
          port: process.port,
          sandbox_process: process,
          request_id: 0,
          pending_requests: %{},
          tools: [],
          initialized: false,
          buffer: ""
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:initialize, from, state) do
    request = %{
      jsonrpc: "2.0",
      id: state.request_id + 1,
      method: "initialize",
      params: %{
        protocolVersion: "2024-11-05",
        capabilities: %{},
        clientInfo: %{
          name: "nex-agent",
          version: "1.0.0"
        }
      }
    }

    send_request(state, request, from)
  end

  @impl true
  def handle_call(:list_tools, from, state) do
    if state.initialized do
      request = %{
        jsonrpc: "2.0",
        id: state.request_id + 1,
        method: "tools/list",
        params: %{}
      }

      send_request(state, request, from)
    else
      {:reply, {:error, :not_initialized}, state}
    end
  end

  @impl true
  def handle_call({:call_tool, name, arguments}, from, state) do
    if state.initialized do
      request = %{
        jsonrpc: "2.0",
        id: state.request_id + 1,
        method: "tools/call",
        params: %{
          name: name,
          arguments: arguments
        }
      }

      send_request(state, request, from)
    else
      {:reply, {:error, :not_initialized}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Accumulate data in buffer, then process complete lines
    buffer = state.buffer <> data
    {lines, remaining} = split_lines(buffer)

    state = %{state | buffer: remaining}

    Enum.reduce(lines, {:noreply, state}, fn line, {_, acc_state} ->
      line = String.trim(line)

      if line == "" do
        {:noreply, acc_state}
      else
        case Jason.decode(line) do
          {:ok, response} ->
            handle_response(response, acc_state)

          {:error, reason} ->
            Logger.warning("Failed to parse MCP response: #{inspect(reason)} - Data: #{line}")
            {:noreply, acc_state}
        end
      end
    end)
  end

  @impl true
  def handle_info({port, :eof}, %{port: port} = state) do
    Logger.info("MCP server closed connection")
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.sandbox_process do
      Exec.close(state.sandbox_process)
    end

    :ok
  end

  # Private functions

  defp send_request(state, request, from) do
    request_id = state.request_id + 1
    request = %{request | id: request_id}

    json = Jason.encode!(request) <> "\n"
    :ok = Exec.write(state.sandbox_process, json)

    new_state = %{
      state
      | request_id: request_id,
        pending_requests: Map.put(state.pending_requests, request_id, from)
    }

    {:noreply, new_state}
  end

  defp handle_response(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        {:noreply, state}

      {from, pending} ->
        new_state = %{state | pending_requests: pending}

        # Check if this is initialize response — send notifications/initialized
        new_state =
          if not state.initialized and is_map(result) and Map.has_key?(result, "capabilities") do
            send_notification(state, %{
              jsonrpc: "2.0",
              method: "notifications/initialized"
            })

            tools = result["tools"] || []
            %{new_state | initialized: true, tools: tools}
          else
            new_state
          end

        GenServer.reply(from, {:ok, result})
        {:noreply, new_state}
    end
  end

  defp handle_response(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _} ->
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, {:error, error})
        {:noreply, %{state | pending_requests: pending}}
    end
  end

  defp handle_response(_response, state) do
    # Ignore notifications (no id)
    {:noreply, state}
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n", parts: :infinity) do
      [] ->
        {[], ""}

      parts ->
        {complete, [remaining]} = Enum.split(parts, -1)
        {complete, remaining}
    end
  end

  defp send_notification(state, notification) do
    json = Jason.encode!(notification) <> "\n"
    :ok = Exec.write(state.sandbox_process, json)
  end

  defp sandbox_policy(opts, cwd) do
    case Keyword.get(opts, :runtime_snapshot) do
      %{sandbox: %Policy{} = policy} ->
        policy

      _ ->
        opts
        |> Keyword.get(:config)
        |> Config.sandbox_runtime(workspace: Keyword.get(opts, :workspace, cwd))
    end
  end
end
