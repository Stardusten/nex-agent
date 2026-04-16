defmodule Nex.Agent.Runtime.Reconciler do
  @moduledoc """
  Applies runtime update events to long-lived runtime consumers.
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Gateway, Runtime}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    case Runtime.subscribe() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Runtime.Reconciler] Subscribe failed: #{inspect(reason)}")
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info({:runtime_updated, %{new_version: _new_version}} = event, state) do
    if Process.whereis(Gateway) do
      _ = Gateway.reconcile(event)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end
