defmodule Nex.Agent.InboundWorker do
  @moduledoc """
  Consume inbound channel messages and route them through Nex.Agent.

  Session strategy is channel + chat scoped (e.g. `telegram:<chat_id>`).
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config, MemoryUpdater, Outbound, Runtime, Workspace}
  alias Nex.Agent.Channel.Discord
  alias Nex.Agent.Channel.Feishu
  alias Nex.Agent.Channel.Feishu.StreamConverter
  alias Nex.Agent.Channel.Feishu.StreamState, as: FeishuStreamState
  alias Nex.Agent.Inbound.Envelope
  alias Nex.Agent.IMIR.Text, as: IMText
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Stream.Result

  @feishu_stream_flush_ms 500

  defstruct [
    :config,
    :agent_start_fun,
    :agent_prompt_fun,
    :agent_abort_fun,
    agents: %{},
    active_tasks: %{},
    agent_last_active: %{},
    pending_queue: %{},
    stream_states: %{}
  ]

  @type agent_start_fun :: (keyword() -> {:ok, term()} | {:error, term()})
  @type agent_prompt_fun :: (term(), String.t(), keyword() ->
                               {:ok, term(), term()} | {:error, term(), term()})
  @type agent_abort_fun :: (term() -> :ok | {:error, term()})

  @type t :: %__MODULE__{
          config: Config.t(),
          agent_start_fun: agent_start_fun(),
          agent_prompt_fun: agent_prompt_fun(),
          agent_abort_fun: agent_abort_fun(),
          agents: %{String.t() => term()},
          active_tasks: %{String.t() => pid()},
          agent_last_active: %{String.t() => integer()},
          pending_queue: %{term() => :queue.queue()},
          stream_states: %{term() => term()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec reset_session(String.t(), String.t(), keyword()) :: :ok
  def reset_session(channel, chat_id, opts \\ []) do
    GenServer.call(__MODULE__, {:reset_session, channel, chat_id, opts})
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      config: Keyword.get(opts, :config, Config.load()),
      agent_start_fun: Keyword.get(opts, :agent_start_fun, &Nex.Agent.start/1),
      agent_prompt_fun: Keyword.get(opts, :agent_prompt_fun, &Nex.Agent.prompt/3),
      agent_abort_fun: Keyword.get(opts, :agent_abort_fun, &Nex.Agent.abort/1),
      agents: %{},
      active_tasks: %{},
      agent_last_active: %{},
      pending_queue: %{},
      stream_states: %{}
    }

    Bus.subscribe(:inbound)
    Process.send_after(self(), :cleanup_stale_agents, 600_000)
    {:ok, state}
  end

  @impl true
  def handle_call({:reset_session, channel, chat_id, opts}, _from, state) do
    session_key = session_key(channel, chat_id)
    workspace = Keyword.get(opts, :workspace, Workspace.root())
    key = runtime_key(workspace, session_key)
    Nex.Agent.reset_session(channel, chat_id, workspace: workspace)
    {:reply, :ok, %{state | agents: Map.delete(state.agents, key)}}
  end

  @impl true
  def handle_info({:bus_message, :inbound, %Envelope{} = envelope}, state) do
    {:noreply, dispatch_inbound(envelope, state)}
  end

  @impl true
  def handle_info({:bus_message, :inbound, payload}, _state) when is_map(payload) do
    raise ArgumentError,
          "InboundWorker expects %Nex.Agent.Inbound.Envelope{} on :inbound, got: #{inspect(payload, limit: 20)}"
  end

  @impl true
  def handle_info({:async_result, key, {:ok, result, updated_agent}, payload}, state) do
    from_cron = Map.get(payload.metadata, "_from_cron") == true
    from_subagent = Map.get(payload.metadata, "_from_subagent") == true

    # Don't overwrite user agent with cron's ephemeral agent
    state =
      if from_cron, do: state, else: put_in(state.agents[key], updated_agent)

    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}
    {state, handled_by_stream?} = finalize_stream_session(state, key, {:ok, result})

    unless from_cron or handled_by_stream? or suppress_outbound?(result) do
      publish_outbound(payload, result)
    end

    maybe_enqueue_memory_refresh(
      updated_agent,
      payload,
      from_cron,
      from_subagent,
      state.agent_prompt_fun
    )

    {:noreply, maybe_drain_pending(state, key)}
  end

  @impl true
  def handle_info({:async_result, key, {:error, reason, updated_agent}, payload}, state) do
    from_cron = Map.get(payload.metadata, "_from_cron") == true
    from_subagent = Map.get(payload.metadata, "_from_subagent") == true

    state =
      if from_cron, do: state, else: put_in(state.agents[key], updated_agent)

    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}
    formatted_reason = streaming_error_message(reason)

    {state, handled_by_stream?} =
      finalize_stream_session(state, key, {:error, formatted_reason, reason})

    unless from_cron or handled_by_stream? or suppress_outbound?(reason) do
      publish_outbound(payload, "Error: #{formatted_reason}")
    end

    maybe_enqueue_memory_refresh(
      updated_agent,
      payload,
      from_cron,
      from_subagent,
      state.agent_prompt_fun
    )

    {:noreply, maybe_drain_pending(state, key)}
  end

  @impl true
  def handle_info({:async_result, key, {:error, reason}, payload}, state) do
    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}
    formatted_reason = streaming_error_message(reason)

    {state, handled_by_stream?} =
      finalize_stream_session(state, key, {:error, formatted_reason, reason})

    unless handled_by_stream? or suppress_outbound?(reason) do
      publish_outbound(payload, "Error: #{formatted_reason}")
    end

    {:noreply, maybe_drain_pending(state, key)}
  end

  @impl true
  def handle_info({:check_timeout, key, pid}, state) do
    if Map.get(state.active_tasks, key) == pid and Process.alive?(pid) do
      Logger.warning("[InboundWorker] Task #{key} timed out after 10 minutes, killing")
      Process.exit(pid, :kill)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    if reason != :normal and reason != :killed do
      Logger.warning("[InboundWorker] Task process #{inspect(pid)} crashed: #{inspect(reason)}")
    end

    active_tasks =
      state.active_tasks
      |> Enum.reject(fn {_key, task_pid} -> task_pid == pid end)
      |> Map.new()

    {:noreply, %{state | active_tasks: active_tasks}}
  end

  @impl true
  def handle_info(:cleanup_stale_agents, state) do
    now = System.system_time(:second)
    # 1 hour TTL
    stale_cutoff = now - 3600

    stale_keys =
      state.agent_last_active
      |> Enum.filter(fn {key, last_active} ->
        last_active < stale_cutoff and not Map.has_key?(state.active_tasks, key)
      end)
      |> Enum.map(&elem(&1, 0))

    if stale_keys != [] do
      Logger.info("[InboundWorker] Cleaning up #{length(stale_keys)} stale agent session(s)")
    end

    agents = Map.drop(state.agents, stale_keys)
    agent_last_active = Map.drop(state.agent_last_active, stale_keys)

    Process.send_after(self(), :cleanup_stale_agents, 600_000)
    {:noreply, %{state | agents: agents, agent_last_active: agent_last_active}}
  end

  @impl true
  def handle_info({:stream_state_started, key, stream_state}, state) do
    {:noreply, put_in(state.stream_states[key], stream_state)}
  end

  @impl true
  def handle_info({:stream_state_event, key, event}, state) do
    case Map.fetch(state.stream_states, key) do
      {:ok, {:feishu, %FeishuStreamState{} = stream_state}} ->
        case apply_feishu_stream_event(stream_state, key, event) do
          {:ok, updated} ->
            {:noreply, put_in(state.stream_states[key], {:feishu, updated})}

          {:error, reason} ->
            Logger.warning("[InboundWorker] feishu stream event failed: #{inspect(reason)}")
            {:noreply, state}
        end

      {:ok, {:text_buffer, buffer}} ->
        updated =
          case event do
            {:text, chunk} when is_binary(chunk) -> {:text_buffer, buffer <> chunk}
            _ -> {:text_buffer, buffer}
          end

        {:noreply, put_in(state.stream_states[key], updated)}

      {:ok, {:discord, discord_state}} ->
        case apply_discord_stream_event(discord_state, event) do
          {:ok, updated} ->
            {:noreply, put_in(state.stream_states[key], {:discord, updated})}

          {:error, reason} ->
            Logger.warning("[InboundWorker] discord stream event failed: #{inspect(reason)}")
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:flush_feishu_stream, key}, state) do
    case Map.fetch(state.stream_states, key) do
      {:ok, {:feishu, %FeishuStreamState{} = stream_state}} ->
        case flush_feishu_stream(stream_state) do
          {:ok, updated} ->
            {:noreply, put_in(state.stream_states[key], {:feishu, updated})}

          {:error, reason} ->
            Logger.warning("[InboundWorker] feishu stream flush failed: #{inspect(reason)}")
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch_inbound(%Envelope{} = envelope, state) do
    channel = envelope.channel
    chat_id = envelope.chat_id |> to_string()
    session_key = session_key(channel, chat_id)
    workspace = payload_workspace(envelope)
    content = normalize_inbound_content(envelope.text)
    cmd = String.trim(content)
    key = runtime_key(workspace, session_key)

    Logger.info(
      "InboundWorker received channel=#{channel} chat_id=#{chat_id} workspace=#{workspace} cmd=#{inspect(cmd)}"
    )

    cond do
      cmd == "" ->
        state

      cmd == "/new" ->
        state = cancel_active_task(state, key)
        publish_outbound(envelope, "New session started.")

        %{
          state
          | agents: Map.delete(state.agents, key),
            pending_queue: Map.delete(state.pending_queue, key)
        }

      cmd == "/stop" ->
        {count, state} = stop_session(state, key, session_key, workspace)
        dropped = :queue.len(Map.get(state.pending_queue, key, :queue.new()))
        state = %{state | pending_queue: Map.delete(state.pending_queue, key)}

        publish_outbound(
          envelope,
          "Stopped #{count} task(s)#{if dropped > 0, do: ", dropped #{dropped} queued message(s)", else: ""}."
        )

        state

      true ->
        if Map.has_key?(state.active_tasks, key) do
          # Session already has an active task — queue this message
          queue = Map.get(state.pending_queue, key, :queue.new())
          queued = {session_key, workspace, content, envelope}
          queue = :queue.in(queued, queue)
          queue_len = :queue.len(queue)

          Logger.info(
            "[InboundWorker] Queued message for busy session #{inspect(key)} (queue=#{queue_len})"
          )

          # Keep max 5 pending messages per session to prevent unbounded growth
          queue =
            if queue_len > 5 do
              {_, trimmed} = :queue.out(queue)
              Logger.warning("[InboundWorker] Dropped oldest queued message for #{inspect(key)}")
              trimmed
            else
              queue
            end

          %{state | pending_queue: Map.put(state.pending_queue, key, queue)}
        else
          dispatch_async(state, key, session_key, workspace, content, envelope)
        end
    end
  end

  defp dispatch_async(state, key, session_key, workspace, content, %Envelope{} = envelope) do
    {channel, chat_id} = parse_session_key(session_key)

    {:ok, agent, state} = ensure_agent(state, key, session_key, workspace)
    parent = self()
    from_cron = get_in(envelope.metadata, ["_from_cron"]) == true
    from_subagent = get_in(envelope.metadata, ["_from_subagent"]) == true
    attachments = envelope.attachments

    cron_opts =
      if from_cron,
        do: [
          history_limit: 0,
          tools_filter: :cron,
          skip_consolidation: true,
          max_iterations: 3,
          skip_skills: true
        ],
        else: []

    unless from_cron or from_subagent do
      Nex.Agent.PersonalSummary.ensure_default_jobs(
        channel,
        chat_id,
        metadata: extract_metadata(envelope),
        workspace: workspace
      )
    end

    {:ok, pid} =
      Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
        try do
          stream_sink =
            if from_cron do
              nil
            else
              build_stream_sink(parent, key, channel, chat_id, envelope, state.config)
            end

          result =
            state.agent_prompt_fun.(
              agent,
              content,
              [
                channel: channel,
                chat_id: chat_id,
                stream_sink: stream_sink,
                workspace: workspace,
                schedule_memory_refresh: false
              ]
              |> maybe_put_opt(:media, attachments)
              |> Kernel.++(cron_opts)
            )

          send(parent, {:async_result, key, result, envelope})
        rescue
          e ->
            send(parent, {:async_result, key, {:error, Exception.message(e)}, envelope})
        catch
          kind, reason ->
            send(parent, {:async_result, key, {:error, "#{kind}: #{inspect(reason)}"}, envelope})
        end
      end)

    Process.monitor(pid)
    Process.send_after(self(), {:check_timeout, key, pid}, 600_000)

    %{
      state
      | active_tasks: Map.put(state.active_tasks, key, pid),
        agent_last_active: Map.put(state.agent_last_active, key, System.system_time(:second))
    }
  end

  defp build_stream_sink(parent, key, channel, chat_id, envelope, config) do
    metadata = extract_metadata(envelope)
    channel_runtime = channel_runtime(envelope, channel, config)
    streaming? = Map.get(channel_runtime, "streaming", false) == true

    cond do
      channel == "feishu" and streaming? ->
        if Process.whereis(Feishu) do
          {:ok, converter} = StreamConverter.start(chat_id, metadata)
          send(
            parent,
            {:stream_state_started,
             key,
             {:feishu, %FeishuStreamState{converter: converter}}}
          )

          fn
            {:text, chunk} when is_binary(chunk) ->
              send(parent, {:stream_state_event, key, {:text, chunk}})
              :ok

            :finish ->
              send(parent, {:stream_state_event, key, :finish})
              :ok

            {:error, message} ->
              send(parent, {:stream_state_event, key, {:error, message}})
              :ok
          end
        else
          nil
        end

      channel == "discord" and streaming? ->
        send(parent, {:stream_state_started, key, {:discord, discord_stream_state(chat_id, metadata)}})

        fn
          {:text, chunk} when is_binary(chunk) ->
            send(parent, {:stream_state_event, key, {:text, chunk}})
            :ok

          :finish ->
            send(parent, {:stream_state_event, key, :finish})
            :ok

          {:error, message} ->
            send(parent, {:stream_state_event, key, {:error, message}})
            :ok
        end

      channel != "feishu" and streaming? ->
        send(parent, {:stream_state_started, key, {:text_buffer, ""}})

        fn
          {:text, chunk} when is_binary(chunk) ->
            send(parent, {:stream_state_event, key, {:text, chunk}})
            :ok

          :finish ->
            send(parent, {:stream_state_event, key, :finish})
            :ok

          {:error, _message} ->
            :ok
        end

      true ->
        nil
    end
  end

  defp channel_runtime(envelope, channel, config) do
    workspace = payload_workspace(envelope)

    case runtime_snapshot_for_workspace(workspace) do
      %Snapshot{workspace: snapshot_workspace, channels: channels}
      when is_map(channels) and is_binary(snapshot_workspace) ->
        if same_workspace?(snapshot_workspace, workspace) do
          Config.channel_runtime(config, channel)
        else
          Map.get(channels, to_string(channel), Config.channel_runtime(config, channel))
        end

      %Snapshot{config: %Config{} = config} ->
        Config.channel_runtime(config, channel)

      _ ->
        Config.channel_runtime(config, channel)
    end
  end

  defp maybe_drain_pending(state, key) do
    case Map.get(state.pending_queue, key) do
      nil ->
        state

      queue ->
        case :queue.out(queue) do
          {{:value, {session_key, workspace, content, envelope}}, rest} ->
            remaining =
              if :queue.is_empty(rest),
                do: Map.delete(state.pending_queue, key),
                else: Map.put(state.pending_queue, key, rest)

            state = %{state | pending_queue: remaining}

            Logger.info(
              "[InboundWorker] Draining queued message for #{inspect(key)} (remaining=#{:queue.len(rest)})"
            )

            dispatch_async(state, key, session_key, workspace, content, envelope)

          {:empty, _} ->
            %{state | pending_queue: Map.delete(state.pending_queue, key)}
        end
    end
  end

  defp cancel_active_task(state, key) do
    case Map.get(state.active_tasks, key) do
      nil ->
        state

      pid ->
        Process.exit(pid, :kill)
        %{state | active_tasks: Map.delete(state.active_tasks, key)}
    end
  end

  defp stop_session(state, key, session_key, workspace) do
    count =
      case Map.get(state.active_tasks, key) do
        nil ->
          0

        pid ->
          Process.exit(pid, :kill)
          1
      end

    subagent_count =
      if Process.whereis(Nex.Agent.Subagent) do
        {:ok, n} = Nex.Agent.Subagent.cancel_by_session(session_key, workspace: workspace)
        n
      else
        0
      end

    state = abort_session_agent(state, key)
    state = %{state | active_tasks: Map.delete(state.active_tasks, key)}
    {count + subagent_count, state}
  end

  defp ensure_agent(state, key, session_key, workspace) do
    case Map.fetch(state.agents, key) do
      {:ok, agent} ->
        if stale_agent?(agent) do
          Logger.info(
            "[InboundWorker] Rebuilding stale agent session=#{session_key} key=#{inspect(key)} " <>
              "agent_runtime_version=#{inspect(agent_runtime_version(agent))} current_runtime_version=#{inspect(Runtime.current_version())}"
          )

          state
          |> update_in([Access.key!(:agents)], &Map.delete(&1, key))
          |> ensure_agent(key, session_key, workspace)
        else
          # Reload session from SessionManager to get latest state
          session = Nex.Agent.SessionManager.get_or_create(session_key, workspace: workspace)
          updated_agent = %{agent | session: session, workspace: workspace}
          {:ok, updated_agent, put_in(state.agents[key], updated_agent)}
        end

      :error ->
        opts = agent_start_opts(session_key, workspace)

        Logger.info(
          "InboundWorker creating new agent session=#{session_key} for key=#{inspect(key)}"
        )

        case state.agent_start_fun.(opts) do
          {:ok, agent} ->
            {:ok, agent, put_in(state.agents[key], agent)}

          {:error, reason} ->
            raise "failed to start agent for #{session_key}: #{inspect(reason)}"
        end
    end
  end

  defp agent_start_opts(session_key, workspace) do
    [channel, chat_id] = String.split(session_key, ":", parts: 2)
    snapshot = runtime_snapshot_for_workspace(workspace)
    config = if snapshot, do: snapshot.config, else: Config.load()
    provider = Config.provider_to_atom(config.provider)
    home = System.get_env("HOME", File.cwd!())

    [
      provider: provider,
      model: config.model,
      api_key: Config.get_current_api_key(config),
      base_url: Config.get_current_base_url(config),
      tools: config.tools,
      workspace: workspace,
      runtime_snapshot: snapshot,
      runtime_version: snapshot && snapshot.version,
      cwd: home,
      max_iterations: Config.get_max_iterations(config),
      channel: channel,
      chat_id: chat_id
    ]
  end

  defp runtime_snapshot_for_workspace(workspace) do
    expanded_workspace = Path.expand(workspace)

    case Runtime.current() do
      {:ok, %Snapshot{workspace: snapshot_workspace} = snapshot}
      when is_binary(snapshot_workspace) ->
        if Path.expand(snapshot_workspace) == expanded_workspace do
          snapshot
        else
          nil
        end

      {:ok, %Snapshot{} = snapshot} ->
        snapshot

      _ ->
        nil
    end
  end

  defp stale_agent?(%Nex.Agent{} = agent) do
    case Runtime.current() do
      {:ok, %Snapshot{version: current_version, workspace: snapshot_workspace}}
      when is_integer(current_version) and is_binary(snapshot_workspace) ->
        if same_workspace?(snapshot_workspace, agent.workspace) do
          stale_agent_runtime_version?(agent, current_version)
        else
          false
        end

      {:ok, %Snapshot{version: current_version}} when is_integer(current_version) ->
        stale_agent_runtime_version?(agent, current_version)

      _ ->
        false
    end
  end

  defp stale_agent?(_agent), do: false

  defp stale_agent_runtime_version?(%Nex.Agent{} = agent, current_version) do
    case agent.runtime_version do
      agent_version when is_integer(agent_version) -> current_version > agent_version
      _ -> true
    end
  end

  defp same_workspace?(left, right) when is_binary(left) and is_binary(right) do
    Path.expand(left) == Path.expand(right)
  end

  defp same_workspace?(_left, _right), do: false

  defp agent_runtime_version(%Nex.Agent{runtime_version: version}), do: version
  defp agent_runtime_version(_agent), do: nil

  defp abort_session_agent(state, key) do
    case Map.fetch(state.agents, key) do
      {:ok, agent} ->
        _ = state.agent_abort_fun.(agent)
        %{state | agents: Map.delete(state.agents, key)}

      :error ->
        state
    end
  end

  defp publish_outbound(%Envelope{} = envelope, content, extra_meta \\ []) do
    channel = envelope.channel
    chat_id = payload_chat_id(envelope)
    outbound_topic = Outbound.topic_for_channel(channel)

    metadata =
      envelope
      |> extract_metadata()
      |> Map.put_new("channel", channel)
      |> Map.put_new("chat_id", chat_id)
      |> Map.merge(Map.new(extra_meta, fn {k, v} -> {to_string(k), v} end))

    # If a streaming CardKit card was created, update it instead of sending a new message.
    card_id = Map.get(envelope.metadata, "_card_id")

    metadata =
      if is_binary(card_id) and card_id != "" do
        Map.put(metadata, "_update_card_id", card_id)
      else
        metadata
      end

    Logger.info("InboundWorker publishing topic=#{inspect(outbound_topic)} chat_id=#{chat_id}")

    Bus.publish(outbound_topic, %{chat_id: chat_id, content: content, metadata: metadata})
  end

  defp extract_metadata(payload) do
    existing = payload.metadata || %{}

    base = %{}

    base =
      maybe_put(
        base,
        "message_id",
        payload.message_id
      )

    base = maybe_put(base, "user_id", payload.user_id)

    if is_map(existing) do
      Map.merge(existing, base)
    else
      base
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_enqueue_memory_refresh(_agent, _payload, true, _from_subagent, _prompt_fun), do: :ok
  defp maybe_enqueue_memory_refresh(_agent, _payload, _from_cron, true, _prompt_fun), do: :ok

  defp maybe_enqueue_memory_refresh(%Nex.Agent{} = agent, _payload, false, false, prompt_fun) do
    if memory_refresh_allowed?(agent, prompt_fun) do
      enqueue_memory_refresh(agent)
    end
  end

  defp memory_refresh_allowed?(%Nex.Agent{} = agent, prompt_fun) do
    metadata = agent.session.metadata || %{}

    default_agent_prompt_fun?(prompt_fun) or
      Map.has_key?(metadata, "memory_refresh_llm_call_fun") or
      Map.has_key?(metadata, "memory_refresh_req_llm_stream_text_fun")
  end

  defp memory_refresh_allowed?(_agent, prompt_fun), do: default_agent_prompt_fun?(prompt_fun)

  defp default_agent_prompt_fun?(fun) when is_function(fun, 3) do
    info = Function.info(fun)

    Keyword.get(info, :type) == :external and
      Keyword.get(info, :module) == Nex.Agent and
      Keyword.get(info, :name) == :prompt and
      Keyword.get(info, :arity) == 3
  end

  defp default_agent_prompt_fun?(_fun), do: false

  defp enqueue_memory_refresh(%Nex.Agent{} = agent) do
    MemoryUpdater.enqueue(
      agent.session,
      provider: agent.provider,
      model: agent.model,
      api_key: agent.api_key,
      base_url: agent.base_url,
      workspace: agent.workspace
    )
  end

  # Suppress LLM outputs that are clearly not real replies to the user.
  # Uses structural checks rather than keyword blocklists.
  defp suppress_outbound?(%Result{handled?: true}), do: true
  defp suppress_outbound?(:message_sent), do: true

  defp suppress_outbound?(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      # Empty or whitespace-only
      trimmed == "" ->
        true

      # Pure punctuation / symbols (no letters or digits)
      Regex.match?(~r/\A[\p{P}\p{S}\s]*\z/u, trimmed) ->
        true

      # Wrapped in parentheses/brackets with no substance outside — e.g. "（xxx）"
      # Typical of LLM "stage directions" like "（静默等待）" or "(no response needed)"
      Regex.match?(~r/\A[(\[（【][^)\]）】]*[)\]）】]\z/u, trimmed) ->
        Logger.warning("[InboundWorker] Suppressed stage-direction output: #{inspect(trimmed)}")
        true

      true ->
        false
    end
  end

  defp suppress_outbound?(_), do: false

  defp finalize_stream_session(state, key, result) do
    case Map.fetch(state.stream_states, key) do
      {:ok, {:feishu, %FeishuStreamState{} = stream_state}} ->
        stream_state = cancel_feishu_flush(stream_state)

        case flush_feishu_stream(stream_state) do
          {:ok, %FeishuStreamState{converter: converter}} ->
            finalize_fun =
              case result do
                {:ok, _value} -> &StreamConverter.finish/1
                {:error, message, _reason} -> &StreamConverter.fail(&1, message)
                {:error, message} -> &StreamConverter.fail(&1, format_reason(message))
              end

            case finalize_fun.(converter) do
              {:ok, _updated} ->
                {%{state | stream_states: Map.delete(state.stream_states, key)}, true}

              {:error, reason} ->
                Logger.warning("[InboundWorker] feishu stream finalize failed: #{inspect(reason)}")
                {%{state | stream_states: Map.delete(state.stream_states, key)}, true}
            end

          {:error, reason} ->
            Logger.warning("[InboundWorker] feishu stream flush before finalize failed: #{inspect(reason)}")
            {%{state | stream_states: Map.delete(state.stream_states, key)}, true}
        end

      {:ok, {:text_buffer, buffer}} ->
        handled? =
          case result do
            {:ok, _value} when is_binary(buffer) and buffer != "" ->
              {channel, chat_id} = parse_session_key(elem(key, 1))
              Bus.publish(Outbound.topic_for_channel(channel), %{chat_id: chat_id, content: buffer, metadata: %{}})
              true

            _ ->
              false
          end

        {%{state | stream_states: Map.delete(state.stream_states, key)}, handled?}

      {:ok, {:discord, discord_state}} ->
        handled? =
          case result do
            {:ok, _value} ->
              case flush_discord_stream(discord_state) do
                {:ok, _updated} ->
                  true

                {:error, reason} ->
                  Logger.warning("[InboundWorker] discord stream finalize failed: #{inspect(reason)}")
                  true
              end

            _ ->
              false
          end

        {%{state | stream_states: Map.delete(state.stream_states, key)}, handled?}

      :error ->
        {state, false}
    end
  end

  defp normalize_inbound_content(content) when is_binary(content), do: content
  defp normalize_inbound_content(nil), do: ""
  defp normalize_inbound_content(content), do: inspect(content, printable_limit: 500, limit: 50)

  defp payload_chat_id(%Envelope{} = payload) do
    payload.chat_id
    |> to_string()
  end

  defp payload_workspace(%Envelope{} = payload) do
    workspace = Map.get(payload.metadata || %{}, "workspace") || Map.get(payload.metadata || %{}, :workspace)

    if is_binary(workspace) and String.trim(workspace) != "" do
      Path.expand(workspace)
    else
      Workspace.root() |> Path.expand()
    end
  end

  defp parse_session_key(key) do
    key_str = to_string(key)

    case String.split(key_str, ":", parts: 2) do
      [channel, chat_id] -> {channel, chat_id}
      [single] -> {single, ""}
      _ -> {"unknown", key_str}
    end
  end

  defp session_key(channel, chat_id), do: "#{channel}:#{chat_id}"
  defp runtime_key(workspace, session_key), do: {Path.expand(workspace), session_key}

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp streaming_error_message(%Result{} = result) do
    result.final_content || format_reason(result.error)
  end

  defp streaming_error_message(reason), do: format_reason(reason)

  defp schedule_feishu_flush(%FeishuStreamState{flush_timer_ref: nil} = stream_state, key) do
    %{stream_state | flush_timer_ref: Process.send_after(self(), {:flush_feishu_stream, key}, @feishu_stream_flush_ms)}
  end

  defp schedule_feishu_flush(stream_state, _key), do: stream_state

  defp cancel_feishu_flush(%FeishuStreamState{flush_timer_ref: nil} = stream_state), do: stream_state

  defp cancel_feishu_flush(%FeishuStreamState{flush_timer_ref: ref} = stream_state) do
    Process.cancel_timer(ref)
    %{stream_state | flush_timer_ref: nil}
  end

  defp flush_feishu_stream(%FeishuStreamState{pending_text: ""} = stream_state) do
    {:ok, %{stream_state | flush_timer_ref: nil}}
  end

  defp flush_feishu_stream(
         %FeishuStreamState{converter: converter, pending_text: pending_text} = stream_state
       ) do
    case StreamConverter.push_text(converter, pending_text) do
      {:ok, updated_converter} ->
        {:ok, %{stream_state | converter: updated_converter, pending_text: "", flush_timer_ref: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_feishu_stream_event(
         %FeishuStreamState{pending_text: pending_text} = stream_state,
         key,
         {:text, chunk}
       )
       when is_binary(chunk) do
    updated =
      %{stream_state | pending_text: pending_text <> chunk}
      |> schedule_feishu_flush(key)

    {:ok, updated}
  end

  defp apply_feishu_stream_event(stream_state, _key, :finish) do
    flush_feishu_stream(cancel_feishu_flush(stream_state))
  end

  defp apply_feishu_stream_event(stream_state, _key, {:error, message}) do
    with {:ok, %FeishuStreamState{converter: converter} = stream_state} <-
           flush_feishu_stream(cancel_feishu_flush(stream_state)),
         {:ok, updated_converter} <- StreamConverter.fail(converter, message) do
      {:ok, %{stream_state | converter: updated_converter}}
    end
  end

  defp discord_stream_state(chat_id, metadata) do
    %{
      chat_id: chat_id,
      metadata: metadata,
      buffer: "",
      current_message_id: nil,
      last_content: nil
    }
  end

  defp apply_discord_stream_event(stream_state, {:text, chunk}) when is_binary(chunk) do
    flush_discord_stream(%{stream_state | buffer: stream_state.buffer <> chunk})
  end

  defp apply_discord_stream_event(stream_state, :finish) do
    flush_discord_stream(stream_state)
  end

  defp apply_discord_stream_event(stream_state, {:error, _message}) do
    {:ok, stream_state}
  end

  defp apply_discord_stream_event(stream_state, _event), do: {:ok, stream_state}

  defp flush_discord_stream(%{buffer: ""} = stream_state), do: {:ok, stream_state}

  defp flush_discord_stream(stream_state) do
    case IMText.split_complete_messages(stream_state.buffer) do
      {[], remainder} ->
        update_or_create_discord_message(%{stream_state | buffer: remainder})

      {segments, remainder} ->
        with {:ok, updated} <- send_discord_segments(stream_state, segments) do
          updated = %{updated | current_message_id: nil, last_content: nil}

          if remainder == "" do
            {:ok, %{updated | buffer: ""}}
          else
            update_or_create_discord_message(%{updated | buffer: remainder})
          end
        end
    end
  end

  defp send_discord_segments(stream_state, segments) do
    Enum.reduce_while(segments, {:ok, stream_state}, fn segment, {:ok, acc} ->
      case send_discord_new_message(acc, segment) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_or_create_discord_message(%{buffer: buffer} = stream_state) do
    content = String.trim(buffer)

    cond do
      content == "" ->
        {:ok, stream_state}

      stream_state.current_message_id == nil ->
        send_discord_new_message(stream_state, content)

      stream_state.last_content == content ->
        {:ok, stream_state}

      true ->
        case Discord.update_message(
               stream_state.chat_id,
               stream_state.current_message_id,
               content,
               stream_state.metadata
             ) do
          :ok -> {:ok, %{stream_state | last_content: content}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp send_discord_new_message(stream_state, content) do
    trimmed = String.trim(content)

    if trimmed == "" do
      {:ok, stream_state}
    else
      case Discord.deliver_message(stream_state.chat_id, trimmed, stream_state.metadata) do
        {:ok, message_id} ->
          {:ok,
           %{
             stream_state
             | current_message_id: message_id,
               last_content: trimmed,
               buffer: trimmed
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
