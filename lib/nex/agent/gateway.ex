defmodule Nex.Agent.Gateway do
  @moduledoc """
  Gateway - Channel orchestrator.

  Manages the lifecycle of channel processes (Feishu, Discord)
  via the ChannelSupervisor (DynamicSupervisor). All infrastructure and worker services
  are managed by the OTP supervision tree in Application.

  Provides start/stop/status/send_message public API.
  """

  use GenServer
  require Logger

  alias Nex.Agent.Channel.Catalog, as: ChannelCatalog

  alias Nex.Agent.Runtime
  alias Nex.Agent.Runtime.Snapshot

  defstruct [:config, :status, :started_at]

  @type status :: :stopped | :starting | :running | :stopping

  @type t :: %__MODULE__{
          config: Nex.Agent.Config.t(),
          status: status(),
          started_at: integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Start all channels and heartbeat tick."
  @spec start() :: :ok | {:error, term()}
  def start do
    GenServer.call(__MODULE__, :start, :infinity)
  end

  @doc "Stop all channels and heartbeat tick."
  @spec stop() :: :ok
  def stop do
    GenServer.call(__MODULE__, :stop, :infinity)
  end

  @doc "Get gateway status and service health."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Send a message through the agent."
  @spec send_message(String.t()) :: {:ok, String.t()} | {:error, term()}
  def send_message(message) do
    GenServer.call(__MODULE__, {:send_message, message}, :infinity)
  end

  @doc "Reconcile channel children against the latest runtime snapshot."
  @spec reconcile(term()) :: :ok | {:error, term()}
  def reconcile(event \\ nil) do
    GenServer.call(__MODULE__, {:reconcile, event}, :infinity)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    config = runtime_config() || Nex.Agent.Config.load()

    state = %__MODULE__{
      config: config,
      status: :stopped,
      started_at: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:start, _from, %{status: :stopped} = state) do
    case do_start(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:start, _from, state) do
    {:reply, {:error, :already_started}, state}
  end

  @impl true
  def handle_call(:stop, _from, %{status: :running} = state) do
    new_state = do_stop(state)
    {:reply, :ok, new_state}
  end

  def handle_call(:stop, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    model_runtime = Nex.Agent.Config.default_model_runtime(state.config)

    status = %{
      status: state.status,
      started_at: state.started_at,
      config: %{
        provider: model_runtime && model_runtime.provider_key,
        model: model_runtime && model_runtime.model_id
      },
      services: %{
        bus: Process.whereis(Nex.Agent.Bus) != nil,
        cron: Process.whereis(Nex.Agent.Cron) != nil,
        heartbeat: Process.whereis(Nex.Agent.Heartbeat) != nil,
        tool_registry: Process.whereis(Nex.Agent.Tool.Registry) != nil,
        inbound_worker: Process.whereis(Nex.Agent.InboundWorker) != nil,
        subagent: Process.whereis(Nex.Agent.Subagent) != nil,
        channels:
          state.config
          |> Nex.Agent.Config.channel_instances()
          |> Enum.into(%{}, fn {id, instance} ->
            {id,
             %{
               type: Map.get(instance, "type"),
               enabled: Map.get(instance, "enabled", false) == true,
               running: Nex.Agent.Channel.Registry.whereis(id) != nil
             }}
          end)
      }
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:reconcile, _event}, _from, %{status: :running} = state) do
    case runtime_snapshot() do
      %Snapshot{config: config} ->
        old_config = state.config
        reconcile_channels(old_config, config)
        {:reply, :ok, %{state | config: config}}

      _ ->
        {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call({:reconcile, _event}, _from, state) do
    case runtime_snapshot() do
      %Snapshot{config: config} ->
        {:reply, :ok, %{state | config: config}}

      _ ->
        {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  @impl true
  def handle_call({:send_message, message}, _from, %{status: :running} = state) do
    case do_send_message(message) do
      {:ok, response} ->
        {:reply, {:ok, response}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_message, _message}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  # --- Private ---

  defp do_start(state) do
    # Refresh from the runtime snapshot to pick up a consistent world view.
    config = runtime_config() || Nex.Agent.Config.load()
    state = %{state | config: config}

    if Nex.Agent.Config.valid?(config) do
      # Start heartbeat tick (may not be running if started outside OTP app)
      if Process.whereis(Nex.Agent.Heartbeat) do
        _ = Nex.Agent.Heartbeat.start()
      end

      start_channels(config)

      {:ok, %{state | status: :running, started_at: System.system_time(:second)}}
    else
      {:error, :invalid_config}
    end
  end

  defp do_stop(state) do
    # Stop heartbeat tick
    if Process.whereis(Nex.Agent.Heartbeat) do
      _ = Nex.Agent.Heartbeat.stop()
    end

    # Terminate all channel children
    stop_channels()

    %{state | status: :stopped, started_at: nil}
  end

  defp start_channels(config) do
    if Process.whereis(Nex.Agent.ChannelSupervisor) do
      specs = channel_specs(config)

      Logger.info("[Gateway] Starting channels: #{inspect(Enum.map(specs, & &1.id))}")

      specs
      |> Enum.each(fn spec ->
        case DynamicSupervisor.start_child(Nex.Agent.ChannelSupervisor, spec) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.warning("[Gateway] Failed to start channel: #{inspect(reason)}")
        end
      end)
    else
      Logger.warning("[Gateway] ChannelSupervisor not running, skipping channel startup")
    end
  end

  defp reconcile_channels(old_config, new_config) do
    old_instances = Nex.Agent.Config.enabled_channel_instances(old_config)
    new_instances = Nex.Agent.Config.enabled_channel_instances(new_config)

    removed = Map.keys(old_instances) -- Map.keys(new_instances)
    added = Map.keys(new_instances) -- Map.keys(old_instances)
    common = Map.keys(old_instances) -- removed

    Enum.each(removed, &stop_channel_instance/1)

    Enum.each(common, fn id ->
      if Map.get(old_instances, id) != Map.get(new_instances, id) do
        restart_channel_instance(id, new_config, Map.fetch!(new_instances, id))
      end
    end)

    Enum.each(added, fn id ->
      start_channel_instance(id, new_config, Map.fetch!(new_instances, id))
    end)
  end

  defp stop_channels do
    if Process.whereis(Nex.Agent.ChannelSupervisor) do
      DynamicSupervisor.which_children(Nex.Agent.ChannelSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Nex.Agent.ChannelSupervisor, pid)
      end)
    end
  end

  defp start_channel_instance(instance_id, config, instance_config) do
    if Process.whereis(Nex.Agent.ChannelSupervisor) do
      case channel_module(instance_config) do
        {:ok, module} ->
          spec = channel_child_spec(module, instance_id, config, instance_config)

          case DynamicSupervisor.start_child(Nex.Agent.ChannelSupervisor, spec) do
            {:ok, _pid} ->
              :ok

            {:error, {:already_started, _pid}} ->
              :ok

            {:error, reason} ->
              Logger.warning("[Gateway] Failed to start #{instance_id}: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[Gateway] Skipping #{instance_id}: #{inspect(reason)}")
      end
    end
  end

  defp stop_channel_instance(instance_id) do
    case Nex.Agent.Channel.Registry.whereis(instance_id) do
      nil ->
        :ok

      pid ->
        if Process.whereis(Nex.Agent.ChannelSupervisor) do
          DynamicSupervisor.terminate_child(Nex.Agent.ChannelSupervisor, pid)
        else
          GenServer.stop(pid)
        end
    end
  end

  defp restart_channel_instance(instance_id, config, instance_config) do
    stop_channel_instance(instance_id)
    start_channel_instance(instance_id, config, instance_config)
  end

  defp channel_specs(config) do
    config
    |> Nex.Agent.Config.enabled_channel_instances()
    |> Enum.flat_map(fn {instance_id, instance_config} ->
      case channel_module(instance_config) do
        {:ok, module} -> [channel_child_spec(module, instance_id, config, instance_config)]
        {:error, _reason} -> []
      end
    end)
  end

  defp channel_child_spec(module, instance_id, config, instance_config) do
    %{
      id: {module, instance_id},
      start:
        {module, :start_link,
         [[instance_id: instance_id, config: config, channel_config: instance_config]]}
    }
  end

  defp channel_module(%{"type" => type}) do
    with {:ok, spec} <- ChannelCatalog.fetch(type) do
      {:ok, spec.gateway_module()}
    end
  end

  defp channel_module(_instance_config), do: {:error, {:unknown_channel_type, nil}}

  defp do_send_message(message) do
    snapshot = runtime_snapshot()
    config = if snapshot, do: snapshot.config, else: Nex.Agent.Config.load()
    model_runtime = Nex.Agent.Config.default_model_runtime(config)

    opts =
      [
        provider: model_runtime && model_runtime.provider,
        model: model_runtime && model_runtime.model_id,
        api_key: model_runtime && model_runtime.api_key,
        base_url: model_runtime && model_runtime.base_url,
        provider_options: model_runtime && model_runtime.provider_options,
        tools: config.tools
      ]
      |> maybe_put(:runtime_snapshot, snapshot)
      |> maybe_put(:runtime_version, snapshot && snapshot.version)

    case Nex.Agent.start(opts) do
      {:ok, agent} ->
        case Nex.Agent.prompt(agent, message) do
          {:ok, response, _agent} ->
            {:ok, render_prompt_result(response)}

          {:error, reason, _agent} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp runtime_config do
    case runtime_snapshot() do
      %Snapshot{config: config} -> config
      _ -> nil
    end
  end

  defp runtime_snapshot do
    case Runtime.current() do
      {:ok, %Snapshot{} = snapshot} -> snapshot
      _ -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp render_prompt_result(%Nex.Agent.Stream.Result{} = result), do: to_string(result)
  defp render_prompt_result(result), do: result
end
