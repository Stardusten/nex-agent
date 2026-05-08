defmodule Nex.Agent.App.Bus do
  @moduledoc """
  Message bus - a simple PubSub implementation.
  """

  use GenServer

  defstruct [:subscribers, :monitors]

  @type t :: %__MODULE__{
          subscribers: %{term() => [pid()]},
          monitors: %{pid() => reference()}
        }

  @doc """
  Start the Bus.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %__MODULE__{subscribers: %{}, monitors: %{}}, name: name)
  end

  @doc """
  Subscribe to a topic.
  """
  @spec subscribe(term(), pid() | nil) :: :ok
  def subscribe(topic \\ :default, pid \\ nil) when is_pid(pid) or is_nil(pid) do
    target_pid = if is_pid(pid), do: pid, else: self()
    GenServer.call(__MODULE__, {:subscribe, topic, target_pid})
  end

  @doc """
  Unsubscribe from a topic.
  """
  @spec unsubscribe(term(), pid() | nil) :: :ok
  def unsubscribe(topic \\ :default, pid \\ nil) when is_pid(pid) or is_nil(pid) do
    target_pid = if is_pid(pid), do: pid, else: self()
    GenServer.call(__MODULE__, {:unsubscribe, topic, target_pid})
  end

  @doc """
  Publish a message.
  """
  @spec publish(term(), term()) :: :ok
  def publish(topic \\ :default, message) do
    GenServer.cast(__MODULE__, {:publish, topic, message})
  end

  @doc """
  Publish a message synchronously and wait for all subscribers to finish processing.
  """
  @spec publish_sync(term(), term()) :: :ok
  def publish_sync(topic \\ :default, message) do
    GenServer.call(__MODULE__, {:publish_sync, topic, message})
  end

  @doc """
  Get the list of subscribers.
  """
  @spec subscribers(term()) :: [pid()]
  def subscribers(topic \\ :default) do
    GenServer.call(__MODULE__, {:subscribers, topic})
  end

  # GenServer callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, topic, pid}, _from, state) do
    subscribers = Map.get(state.subscribers, topic, [])

    if pid in subscribers do
      {:reply, :ok, state}
    else
      state = monitor_pid(state, pid)
      new_subscribers = [pid | subscribers]
      new_state = %{state | subscribers: Map.put(state.subscribers, topic, new_subscribers)}
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:unsubscribe, topic, pid}, _from, state) do
    subscribers = Map.get(state.subscribers, topic, [])
    new_subscribers = List.delete(subscribers, pid)
    subscribers = Map.put(state.subscribers, topic, new_subscribers)
    new_state = %{state | subscribers: subscribers} |> demonitor_if_unused(pid)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:publish_sync, topic, message}, _from, state) do
    subscribers = Map.get(state.subscribers, topic, [])

    Enum.each(subscribers, fn pid ->
      send(pid, {:bus_message, topic, message})
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:subscribers, topic}, _from, state) do
    {:reply, Map.get(state.subscribers, topic, []), state}
  end

  @impl true
  def handle_cast({:publish, topic, message}, state) do
    subscribers = Map.get(state.subscribers, topic, [])

    Enum.each(subscribers, fn pid ->
      send(pid, {:bus_message, topic, message})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers =
      state.subscribers
      |> Enum.map(fn {topic, subscribers} ->
        {topic, List.delete(subscribers, pid)}
      end)
      |> Map.new()

    {:noreply, %{state | subscribers: new_subscribers, monitors: Map.delete(state.monitors, pid)}}
  end

  defp monitor_pid(%__MODULE__{} = state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      %{state | monitors: Map.put(state.monitors, pid, Process.monitor(pid))}
    end
  end

  defp demonitor_if_unused(%__MODULE__{} = state, pid) do
    if subscribed_anywhere?(state.subscribers, pid) do
      state
    else
      case Map.pop(state.monitors, pid) do
        {nil, monitors} ->
          %{state | monitors: monitors}

        {ref, monitors} ->
          Process.demonitor(ref, [:flush])
          %{state | monitors: monitors}
      end
    end
  end

  defp subscribed_anywhere?(subscribers_by_topic, pid) do
    Enum.any?(subscribers_by_topic, fn {_topic, subscribers} -> pid in subscribers end)
  end
end
