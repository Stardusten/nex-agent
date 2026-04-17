defmodule Nex.Agent.Channel.Discord.WSClient do
  @moduledoc false

  use WebSockex

  require Logger

  @spec start_link(String.t(), list(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_link(url, headers, parent_pid) do
    WebSockex.start_link(url, __MODULE__, %{parent: parent_pid}, extra_headers: headers)
  end

  @spec send_json(pid(), map()) :: :ok
  def send_json(pid, payload) when is_pid(pid) and is_map(payload) do
    WebSockex.cast(pid, {:send_json, payload})
  end

  @impl true
  def handle_connect(_conn, state) do
    send(state.parent, {:discord_ws_connected, self()})
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    send(state.parent, {:discord_ws_disconnected, self(), reason})
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, data}, state) when is_binary(data) do
    send(state.parent, {:discord_ws_message, self(), data})
    {:ok, state}
  end

  @impl true
  def handle_frame({:ping, payload}, state) do
    {:reply, {:pong, payload}, state}
  end

  @impl true
  def handle_frame({:binary, data}, state) when is_binary(data) do
    Logger.debug("[Discord] Ignoring unexpected binary frame size=#{byte_size(data)}")
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_json, payload}, state) do
    {:reply, {:text, Jason.encode!(payload)}, state}
  end
end
