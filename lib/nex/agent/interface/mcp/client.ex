defmodule Nex.Agent.Interface.MCP.Client do
  @moduledoc """
  Protocol-level MCP client.

  The client owns JSON-RPC request ids, pending responses, protocol methods,
  and initialization state. Transport modules own wire encoding/framing and
  forward decoded responses back to this process.
  """

  use GenServer

  alias Nex.Agent.Interface.MCP.Transport.{Stdio, StreamableHTTP}

  @default_timeout 30_000
  @protocol_version "2025-11-25"

  defstruct [
    :transport_pid,
    :transport_module,
    request_id: 0,
    pending_requests: %{},
    initialized: false
  ]

  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(opts) do
    case resolve_transport(opts) do
      {:ok, transport_module, transport_opts} ->
        GenServer.start_link(__MODULE__, {transport_module, transport_opts})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec initialize(pid(), timeout()) :: :ok | {:error, term()}
  def initialize(pid, timeout \\ @default_timeout) do
    GenServer.call(pid, :initialize, timeout)
  end

  @spec list_tools(pid(), timeout()) :: {:ok, map() | list()} | {:error, term()}
  def list_tools(pid, timeout \\ @default_timeout) do
    GenServer.call(pid, :list_tools, timeout)
  end

  @spec call_tool(pid(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def call_tool(pid, name, arguments \\ %{}, timeout \\ @default_timeout) do
    GenServer.call(pid, {:call_tool, name, arguments}, timeout)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({transport_module, transport_opts}) do
    transport_opts = put_opt(transport_opts, :owner, self())

    case transport_module.start_link(transport_opts) do
      {:ok, transport_pid} ->
        {:ok, %__MODULE__{transport_pid: transport_pid, transport_module: transport_module}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:initialize, from, state) do
    request = %{
      jsonrpc: "2.0",
      method: "initialize",
      params: %{
        protocolVersion: @protocol_version,
        capabilities: %{},
        clientInfo: %{name: "nex-agent", version: "1.0.0"}
      }
    }

    send_request(state, request, from, :initialize)
  end

  def handle_call(:list_tools, from, state) do
    if state.initialized do
      send_request(state, %{jsonrpc: "2.0", method: "tools/list", params: %{}}, from, :list_tools)
    else
      {:reply, {:error, :not_initialized}, state}
    end
  end

  def handle_call({:call_tool, name, arguments}, from, state) do
    if state.initialized do
      request = %{
        jsonrpc: "2.0",
        method: "tools/call",
        params: %{name: name, arguments: arguments || %{}}
      }

      send_request(state, request, from, :call_tool)
    else
      {:reply, {:error, :not_initialized}, state}
    end
  end

  @impl true
  def handle_info(
        {:mcp_transport_response, transport_pid, response},
        %{transport_pid: transport_pid} = state
      ) do
    handle_response(response, state)
  end

  def handle_info(
        {:mcp_transport_closed, transport_pid, reason},
        %{transport_pid: transport_pid} = state
      ) do
    reply_pending(state.pending_requests, {:error, {:transport_closed, reason}})
    {:stop, :normal, %{state | pending_requests: %{}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.transport_pid do
      state.transport_module.stop(state.transport_pid)
    end

    :ok
  end

  defp send_request(state, request, from, method) do
    request_id = state.request_id + 1
    request = Map.put(request, :id, request_id)
    pending_requests = Map.put(state.pending_requests, request_id, %{from: from, method: method})
    next_state = %{state | request_id: request_id, pending_requests: pending_requests}

    case next_state.transport_module.send_request(next_state.transport_pid, request) do
      :ok ->
        {:noreply, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp send_notification(state, notification) do
    _ = state.transport_module.send_request(state.transport_pid, notification)

    :ok
  end

  defp handle_response(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, method: method}, pending} ->
        next_state = %{state | pending_requests: pending}
        next_state = maybe_mark_initialized(next_state, method)

        GenServer.reply(from, response_for_method(method, result))
        {:noreply, next_state}
    end
  end

  defp handle_response(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, error})
        {:noreply, %{state | pending_requests: pending}}
    end
  end

  defp handle_response(_notification_or_unknown, state), do: {:noreply, state}

  defp maybe_mark_initialized(%{initialized: false} = state, :initialize) do
    send_notification(state, %{jsonrpc: "2.0", method: "notifications/initialized"})
    %{state | initialized: true}
  end

  defp maybe_mark_initialized(state, _method), do: state

  defp response_for_method(:initialize, _result), do: :ok
  defp response_for_method(_method, result), do: {:ok, result}

  defp reply_pending(pending_requests, response) do
    Enum.each(pending_requests, fn {_id, %{from: from}} -> GenServer.reply(from, response) end)
  end

  defp resolve_transport(opts) do
    transport = opts |> get_opt(:transport) |> normalize_transport()

    case transport do
      "stdio" -> {:ok, Stdio, opts}
      "streamable-http" -> {:ok, StreamableHTTP, opts}
      nil -> {:error, :transport_required}
      other -> {:error, {:unsupported_transport, other}}
    end
  end

  defp normalize_transport(nil), do: nil

  defp normalize_transport(value) do
    transport =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if transport == "", do: nil, else: transport
  end

  defp put_opt(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)
  defp put_opt(opts, key, value) when is_map(opts), do: Map.put(opts, key, value)
  defp put_opt(_opts, key, value), do: [{key, value}]

  defp get_opt(opts, key), do: get_opt(opts, key, nil)

  defp get_opt(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp get_opt(opts, key, default) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp get_opt(_opts, _key, default), do: default
end
