defmodule Nex.Agent.Interface.MCP do
  @moduledoc """
  MCP client facade for connecting to Model Context Protocol servers.

  Protocol operations are implemented by `Nex.Agent.Interface.MCP.Client`.
  Transport details live under `Nex.Agent.Interface.MCP.Transport.*`.
  """

  alias Nex.Agent.Interface.MCP.Client

  @timeout 30_000

  @callback initialize(pid(), timeout()) :: :ok | {:error, term()}
  @callback list_tools(pid(), timeout()) :: {:ok, map() | list()} | {:error, term()}
  @callback call_tool(pid(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  @callback stop(pid()) :: :ok

  @doc """
  Start a new MCP client connection.
  """
  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(opts), do: Client.start_link(opts)

  @doc """
  Initialize the MCP connection.
  """
  @spec initialize(pid(), timeout()) :: :ok | {:error, term()}
  def initialize(pid, timeout \\ @timeout), do: Client.initialize(pid, timeout)

  @doc """
  List available tools from the MCP server.
  """
  @spec list_tools(pid(), timeout()) :: {:ok, map() | list()} | {:error, term()}
  def list_tools(pid, timeout \\ @timeout), do: Client.list_tools(pid, timeout)

  @doc """
  Call a tool on the MCP server.
  """
  @spec call_tool(pid(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def call_tool(pid, name, arguments \\ %{}, timeout \\ @timeout),
    do: Client.call_tool(pid, name, arguments, timeout)

  @doc """
  Stop the MCP connection.
  """
  @spec stop(pid()) :: :ok
  def stop(pid), do: Client.stop(pid)
end
