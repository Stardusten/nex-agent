defmodule Nex.Agent.MCP.ServerManager do
  @moduledoc """
  MCP Server manager - dynamically start/stop MCP servers.

  Supports both stdio and HTTP transports, with configuration-based auto-start.

  ## Usage

      # Start an MCP server (stdio)
      {:ok, server_id} = Nex.Agent.MCP.ServerManager.start("filesystem", [
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/test/data"]
      ])

      # Start an MCP server (HTTP)
      {:ok, server_id} = Nex.Agent.MCP.ServerManager.start("github", [
        url: "https://mcp.example.com/github",
        headers: %{"Authorization" => "Bearer xxx"},
        tool_timeout: 120
      ])

      # Call a tool
      {:ok, result} = Nex.Agent.MCP.ServerManager.call_tool(server_id, "read_file", %{path: "..."})

      # Stop a server
      :ok = Nex.Agent.MCP.ServerManager.stop(server_id)

      # List running servers
      servers = Nex.Agent.MCP.ServerManager.list()

  ## Configuration-based Auto-start

  Configure MCP servers in config:

      config :nex_agent, :mcp_servers, %{
        "filesystem" => %{
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/dir"],
          tool_timeout: 60
        },
        "github" => %{
          url: "https://mcp.example.com/github",
          headers: %{"Authorization" => "Bearer xxx"},
          tool_timeout: 120
        }
      }

  Then call `start_configured/0` to auto-start all configured servers.
  """

  use GenServer
  require Logger

  @name __MODULE__

  defstruct [:servers, :tool_registry]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts ++ [name: @name])
  end

  @doc """
  Start an MCP server with the given config.

  ## Parameters

  * `name` - Server name (for identification)
  * `config` - Server configuration keyword list or map

  ## Config Options (Stdio)

  * `:command` - Command to run (e.g., "npx", "python")
  * `:args` - Command arguments (list)
  * `:env` - Environment variables (map)
  * `:tool_timeout` - Tool call timeout in seconds (default: 30)

  ## Config Options (HTTP)

  * `:url` - HTTP endpoint URL
  * `:headers` - HTTP headers (map)
  * `:tool_timeout` - Tool call timeout in seconds (default: 30)

  ## Examples

      {:ok, server_id} = Nex.Agent.MCP.ServerManager.start("filesystem", [
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      ])

      {:ok, server_id} = Nex.Agent.MCP.ServerManager.start("github", [
        url: "https://mcp.example.com/github",
        headers: %{"Authorization" => "Bearer xxx"}
      ])
  """
  @spec start(String.t(), keyword() | map()) :: {:ok, String.t()} | {:error, String.t()}
  def start(name, config) do
    GenServer.call(@name, {:start, name, config})
  end

  @doc """
  Stop a running MCP server.
  """
  @spec stop(String.t()) :: :ok | {:error, String.t()}
  def stop(server_id) do
    GenServer.call(@name, {:stop, server_id})
  end

  @doc """
  Call a tool on an MCP server.
  """
  @spec call_tool(String.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def call_tool(server_id, tool_name, arguments) do
    GenServer.call(@name, {:call_tool, server_id, tool_name, arguments}, 60_000)
  end

  @doc """
  List all running servers.
  """
  @spec list() :: [map()]
  def list do
    GenServer.call(@name, :list)
  end

  @doc """
  Find a running server by name. Returns `{:ok, server_id}` or `:error`.
  """
  @spec get_by_name(String.t()) :: {:ok, String.t()} | :error
  def get_by_name(name) do
    GenServer.call(@name, {:get_by_name, name})
  end

  @doc """
  Discover and auto-start available MCP servers from config.
  """
  @spec start_configured() :: {:ok, [String.t()]} | {:error, String.t()}
  def start_configured do
    GenServer.call(@name, :start_configured)
  end

  @doc """
  Start configured servers and register tools to registry.
  """
  @spec start_and_register(Registry.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def start_and_register(registry) do
    GenServer.call(@name, {:start_and_register, registry})
  end

  @doc """
  Register tools from a running MCP server to the Tool Registry.
  """
  @spec register_tools(String.t()) :: :ok | {:error, String.t()}
  def register_tools(server_id) do
    GenServer.call(@name, {:register_tools, server_id})
  end

  # Server Callbacks

  @impl true
  def init([]) do
    {:ok, %{servers: %{}}}
  end

  @impl true
  def handle_call({:start, name, config}, _from, state) do
    server_id = "#{name}-#{:crypto.strong_rand_bytes(4) |> Base.encode16()}"

    # Normalize config to keyword list
    normalized = normalize_config(config)

    case Nex.Agent.MCP.start_link(normalized) do
      {:ok, pid} ->
        # Initialize the connection
        case Nex.Agent.MCP.initialize(pid) do
          {:ok, _init_result} ->
            # Get tool timeout from config
            tool_timeout = Keyword.get(normalized, :tool_timeout, 30)

            new_servers =
              Map.put(state.servers, server_id, %{
                pid: pid,
                name: name,
                config: normalized,
                tool_timeout: tool_timeout,
                tools: []
              })

            Logger.info("[MCP] Started server '#{name}' (id: #{server_id})")
            {:reply, {:ok, server_id}, %{state | servers: new_servers}}

          {:error, reason} ->
            Nex.Agent.MCP.stop(pid)
            {:reply, {:error, "Failed to initialize: #{inspect(reason)}"}, state}
        end

      {:error, reason} ->
        {:reply, {:error, "Failed to start: #{inspect(reason)}"}, state}
    end
  end

  @impl true
  def handle_call({:stop, server_id}, _from, state) do
    case Map.get(state.servers, server_id) do
      nil ->
        {:reply, {:error, "Server not found"}, state}

      server ->
        Nex.Agent.MCP.stop(server.pid)
        new_servers = Map.delete(state.servers, server_id)
        Logger.info("[MCP] Stopped server '#{server.name}' (id: #{server_id})")
        {:reply, :ok, %{state | servers: new_servers}}
    end
  end

  @impl true
  def handle_call({:call_tool, server_id, tool_name, arguments}, _from, state) do
    case Map.get(state.servers, server_id) do
      nil ->
        {:reply, {:error, "Server not found"}, state}

      server ->
        timeout = (server.tool_timeout || 30) * 1000
        result = Nex.Agent.MCP.call_tool(server.pid, tool_name, arguments, timeout)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    servers =
      Enum.map(state.servers, fn {id, config} ->
        %{
          id: id,
          name: config.name,
          config: config.config,
          tool_timeout: config.tool_timeout,
          tools_count: length(config.tools)
        }
      end)

    {:reply, servers, state}
  end

  @impl true
  def handle_call({:get_by_name, name}, _from, state) do
    result =
      Enum.find_value(state.servers, :error, fn {id, server} ->
        if server.name == name, do: {:ok, id}
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:start_configured, _from, state) do
    configured = Application.get_env(:nex_agent, :mcp_servers, %{})

    results =
      Enum.map(configured, fn {name, config} ->
        case start(name, config) do
          {:ok, server_id} -> {:ok, server_id}
          error -> error
        end
      end)

    successes = Enum.filter(results, &match?({:ok, _}, &1))
    {:reply, {:ok, Enum.map(successes, fn {:ok, id} -> id end)}, state}
  end

  @impl true
  def handle_call({:start_and_register, registry}, _from, state) do
    # First start configured servers
    {:ok, server_ids} = start_configured()

    # Then register their tools
    Enum.each(server_ids, fn server_id ->
      register_tools_to_registry(server_id, registry)
    end)

    {:reply, {:ok, server_ids}, state}
  end

  @impl true
  def handle_call({:register_tools, server_id}, _from, state) do
    case Map.get(state.servers, server_id) do
      nil ->
        {:reply, {:error, "Server not found"}, state}

      server ->
        # Get tools from MCP server
        case Nex.Agent.MCP.list_tools(server.pid) do
          {:ok, tools} ->
            # Update server state with tools
            new_servers = put_in(state.servers[server_id].tools, tools)
            {:reply, {:ok, length(tools)}, %{state | servers: new_servers}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Stop all servers
    Enum.each(state.servers, fn {_, server} ->
      Nex.Agent.MCP.stop(server.pid)
    end)

    :ok
  end

  # Private functions

  defp normalize_config(config) when is_map(config) do
    config
    |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp normalize_config(config) when is_list(config), do: config

  defp register_tools_to_registry(server_id, registry) do
    case Map.get(registry, server_id) do
      nil ->
        :ok

      server ->
        case Nex.Agent.MCP.list_tools(server.pid) do
          {:ok, tools} ->
            # Would register each tool to registry here
            # For now just log
            Logger.info("[MCP] Would register #{length(tools)} tools from #{server.name}")
            :ok

          {:error, _} ->
            :ok
        end
    end
  end
end
