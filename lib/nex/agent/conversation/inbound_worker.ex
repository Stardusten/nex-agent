defmodule Nex.Agent.Conversation.InboundWorker do
  @moduledoc """
  Consume inbound channel messages and route them through Nex.Agent.

  Session strategy is channel + chat scoped (e.g. `feishu:<chat_id>`).
  """

  use GenServer
  require Logger
  require Nex.Agent.Observe.ControlPlane.Log

  alias Nex.Agent.{
    App.Bus,
    Conversation.Command,
    Runtime.Config,
    Conversation.FollowUp,
    Interface.HTTP,
    Interface.Outbound,
    Conversation.RunControl,
    Runtime,
    Conversation.Session,
    Conversation.SessionManager,
    Runtime.Workspace,
    Sandbox.Approval
  }

  alias Nex.Agent.Conversation.Command.Invocation
  alias Nex.Agent.Conversation.Command.StatusView
  alias Nex.Agent.Interface.Outbound.Action, as: OutboundAction
  alias Nex.Agent.Interface.Channel.Catalog, as: ChannelCatalog
  alias Nex.Agent.Knowledge.Memory.Updater, as: MemoryUpdater
  alias Nex.Agent.Observe.ControlPlane.{Query, Redactor}
  alias Nex.Agent.Interface.Inbound.Envelope
  alias Nex.Agent.Interface.Media.{Hydrator, Projector, Ref}
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Turn.Stream.Result

  @max_inbound_attachment_bytes 20 * 1024 * 1024
  @empty_message_text "_(Empty Message)_"

  defstruct [
    :config,
    :agent_start_fun,
    :agent_prompt_fun,
    :agent_abort_fun,
    agents: %{},
    active_tasks: %{},
    active_follow_ups: %{},
    agent_last_active: %{},
    pending_queue: %{},
    stream_states: %{}
  ]

  @type agent_start_fun :: (keyword() -> {:ok, term()} | {:error, term()})
  @type agent_prompt_fun :: (term(), String.t(), keyword() ->
                               {:ok, term(), term()} | {:error, term(), term()})
  @type agent_abort_fun :: (term() -> :ok | {:error, term()})
  @type active_run_entry :: %{
          pid: pid(),
          run_id: String.t(),
          workspace: String.t(),
          session_key: String.t()
        }

  @type active_follow_up_entry :: %{
          pid: pid(),
          workspace: String.t(),
          session_key: String.t(),
          typing_timer_ref: reference() | nil
        }

  @type follow_up_mode :: :busy | :idle

  @type t :: %__MODULE__{
          config: Config.t(),
          agent_start_fun: agent_start_fun(),
          agent_prompt_fun: agent_prompt_fun(),
          agent_abort_fun: agent_abort_fun(),
          agents: %{String.t() => term()},
          active_tasks: %{String.t() => active_run_entry()},
          active_follow_ups: %{String.t() => active_follow_up_entry()},
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

  @spec request_interrupt(String.t(), String.t(), term(), keyword()) ::
          {:ok, %{cancelled?: boolean(), run_id: String.t() | nil}}
  def request_interrupt(workspace, session_key, reason, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:request_interrupt, Path.expand(workspace), session_key, reason, opts}
    )
  end

  @spec stop_session(String.t(), String.t(), term(), keyword()) ::
          {:ok,
           %{
             cancelled?: boolean(),
             run_id: String.t() | nil,
             count: non_neg_integer(),
             dropped_queued: non_neg_integer()
           }}
  def stop_session(workspace, session_key, reason \\ :user_stop, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:stop_session, Path.expand(workspace), session_key, reason, opts}
    )
  end

  @spec invalidate_agent_session(String.t(), String.t(), keyword()) :: :ok
  def invalidate_agent_session(workspace, session_key, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:invalidate_agent_session, Path.expand(workspace), session_key}
    )
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
      active_follow_ups: %{},
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
    state = cancel_follow_up_task(state, key)
    state = cancel_active_task(state, key, session_key, workspace, :reset_session)
    reset_current_session(session_key, workspace)
    {:reply, :ok, %{state | agents: Map.delete(state.agents, key)}}
  end

  @impl true
  def handle_call({:request_interrupt, workspace, session_key, reason, opts}, _from, state) do
    workspace = Keyword.get(opts, :workspace, workspace)
    key = runtime_key(workspace, session_key)

    {reply, state} =
      request_interrupt_impl(
        state,
        key,
        session_key,
        workspace,
        reason,
        Keyword.get(opts, :requester_pid)
      )

    {:reply, reply, state}
  end

  def handle_call({:stop_session, workspace, session_key, reason, opts}, _from, state) do
    workspace = Keyword.get(opts, :workspace, workspace)
    key = runtime_key(workspace, session_key)

    {{:ok, result}, state} =
      request_interrupt_impl(
        state,
        key,
        session_key,
        workspace,
        reason,
        Keyword.get(opts, :requester_pid)
      )

    dropped = queued_count(state, key)
    state = %{state | pending_queue: Map.delete(state.pending_queue, key)}
    state = update_queue_count(state, key, 0)

    if dropped > 0 do
      {channel, chat_id} = parse_session_key(session_key)
      observe_queue_changed(workspace, session_key, channel, chat_id, "drop", 0, dropped)
    end

    {:reply, {:ok, Map.put(result, :dropped_queued, dropped)}, state}
  end

  def handle_call({:invalidate_agent_session, workspace, session_key}, _from, state) do
    key = runtime_key(workspace, session_key)
    {:reply, :ok, %{state | agents: Map.delete(state.agents, key)}}
  end

  @impl true
  def handle_info({:bus_message, :inbound, %Envelope{} = envelope}, state) do
    {:noreply, dispatch_inbound(envelope, state)}
  end

  @impl true
  def handle_info({:bus_message, :inbound, payload}, _state) when is_map(payload) do
    raise ArgumentError,
          "InboundWorker expects %Nex.Agent.Interface.Inbound.Envelope{} on :inbound, got: #{inspect(payload, limit: 20)}"
  end

  @impl true
  def handle_info({:async_result, key, run_id, {:ok, result, updated_agent}, payload}, state) do
    from_cron = Map.get(payload.metadata, "_from_cron") == true
    from_subagent = Map.get(payload.metadata, "_from_subagent") == true

    if current_owner_run?(state, key, run_id) and RunControl.finish_owner(run_id, result) == :ok do
      observe_owner_dispatch(
        "inbound.owner.dispatch.finished",
        :info,
        payload,
        run_id,
        %{"result_status" => "ok"}
      )

      state =
        if from_cron, do: state, else: put_in(state.agents[key], updated_agent)

      state = clear_active_task(state, key, run_id)

      {state, handled_by_stream?} =
        finalize_stream_session(state, stream_key(key, run_id), {:ok, result})

      unless from_cron or handled_by_stream? do
        cond do
          suppress_outbound?(result) and empty_content?(result) ->
            publish_outbound(payload, @empty_message_text)

          suppress_outbound?(result) ->
            :ok

          true ->
            publish_outbound(payload, result)
        end
      end

      publish_task_complete(payload, :ok)

      maybe_enqueue_memory_refresh(
        updated_agent,
        payload,
        from_cron,
        from_subagent,
        state.agent_prompt_fun,
        state.config
      )

      {:noreply, maybe_drain_pending(state, key)}
    else
      Logger.info(
        "[InboundWorker] Dropping stale async success for #{inspect(key)} run_id=#{run_id}"
      )

      {:noreply, drop_stream_state(state, stream_key(key, run_id))}
    end
  end

  @impl true
  def handle_info({:async_result, key, run_id, {:error, reason, updated_agent}, payload}, state) do
    from_cron = Map.get(payload.metadata, "_from_cron") == true
    from_subagent = Map.get(payload.metadata, "_from_subagent") == true

    if current_owner_run?(state, key, run_id) and RunControl.fail_owner(run_id, reason) == :ok do
      observe_owner_dispatch(
        "inbound.owner.dispatch.failed",
        :error,
        payload,
        run_id,
        error_attrs(reason)
      )

      state =
        if from_cron, do: state, else: put_in(state.agents[key], updated_agent)

      state = clear_active_task(state, key, run_id)
      formatted_reason = streaming_error_message(reason)

      {state, handled_by_stream?} =
        finalize_stream_session(
          state,
          stream_key(key, run_id),
          {:error, formatted_reason, reason}
        )

      unless from_cron or handled_by_stream? or suppress_outbound?(reason) do
        publish_outbound(payload, "Error: #{formatted_reason}")
      end

      publish_task_complete(payload, :error)

      maybe_enqueue_memory_refresh(
        updated_agent,
        payload,
        from_cron,
        from_subagent,
        state.agent_prompt_fun,
        state.config
      )

      {:noreply, maybe_drain_pending(state, key)}
    else
      Logger.info(
        "[InboundWorker] Dropping stale async error for #{inspect(key)} run_id=#{run_id}"
      )

      {:noreply, drop_stream_state(state, stream_key(key, run_id))}
    end
  end

  @impl true
  def handle_info({:async_result, key, run_id, {:error, reason}, payload}, state) do
    if current_owner_run?(state, key, run_id) and RunControl.fail_owner(run_id, reason) == :ok do
      observe_owner_dispatch(
        "inbound.owner.dispatch.failed",
        :error,
        payload,
        run_id,
        error_attrs(reason)
      )

      state = clear_active_task(state, key, run_id)
      formatted_reason = streaming_error_message(reason)

      {state, handled_by_stream?} =
        finalize_stream_session(
          state,
          stream_key(key, run_id),
          {:error, formatted_reason, reason}
        )

      unless handled_by_stream? or suppress_outbound?(reason) do
        publish_outbound(payload, "Error: #{formatted_reason}")
      end

      publish_task_complete(payload, :error)

      {:noreply, maybe_drain_pending(state, key)}
    else
      Logger.info(
        "[InboundWorker] Dropping stale async failure for #{inspect(key)} run_id=#{run_id}"
      )

      {:noreply, drop_stream_state(state, stream_key(key, run_id))}
    end
  end

  @impl true
  def handle_info({:follow_up_result, key, pid, result, %Envelope{} = payload}, state) do
    state = clear_follow_up_task(state, key, pid)

    case result do
      {:ok, response, updated_agent} ->
        observe_follow_up("inbound.follow_up.finished", :info, payload, %{
          "result_status" => "ok"
        })

        state = maybe_store_follow_up_agent(state, payload, updated_agent)

        unless suppress_outbound?(response) and empty_content?(response) do
          publish_outbound(payload, response, _from_follow_up: true)
        end

        {:noreply, state}

      {:error, reason, updated_agent} ->
        observe_follow_up("inbound.follow_up.failed", :error, payload, error_attrs(reason))
        state = maybe_store_follow_up_agent(state, payload, updated_agent)
        maybe_publish_follow_up_error(payload, reason)
        {:noreply, state}

      {:error, reason} ->
        observe_follow_up("inbound.follow_up.failed", :error, payload, error_attrs(reason))
        maybe_publish_follow_up_error(payload, reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:check_timeout, key, pid}, state) do
    if active_task_pid(state, key) == pid and Process.alive?(pid) do
      Logger.warning("[InboundWorker] Task #{inspect(key)} timed out after 10 minutes, killing")
      observe_owner_timeout(state, key)
      Process.exit(pid, :kill)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    cond do
      match = find_follow_up_by_pid(state, pid) ->
        {key, entry} = match

        if reason != :normal and reason != :killed do
          Logger.warning(
            "[InboundWorker] Follow-up task #{inspect(pid)} exited: #{inspect(reason)}"
          )

          observe_follow_up_exit(key, entry, reason)
        end

        {:noreply, delete_follow_up_task(state, key)}

      match = find_active_task_by_pid(state, pid) ->
        {key, %{run_id: run_id, workspace: workspace, session_key: session_key}} = match

        if reason != :normal and reason != :killed do
          Logger.warning(
            "[InboundWorker] Task process #{inspect(pid)} crashed: #{inspect(reason)}"
          )

          observe_owner_process_exit(workspace, session_key, run_id, reason)
        end

        _ =
          case reason do
            :normal -> RunControl.fail_owner(run_id, :task_exited)
            :killed -> RunControl.cancel_owner(workspace, session_key, :killed)
            _ -> RunControl.fail_owner(run_id, reason)
          end

        state =
          state
          |> drop_stream_state(stream_key(key, run_id))
          |> Map.update!(:active_tasks, &Map.delete(&1, key))

        {:noreply, state}

      true ->
        {:noreply, state}
    end
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
    if current_owner_run?(state, stream_runtime_key(key), stream_run_id(key)) do
      _ = RunControl.set_phase(stream_run_id(key), :streaming)
      {:noreply, put_in(state.stream_states[key], stream_state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:stream_state_event, key, event}, state) do
    case event do
      {:text, chunk} when is_binary(chunk) ->
        _ = RunControl.append_assistant_partial(stream_run_id(key), chunk)

      _ ->
        :ok
    end

    case Map.fetch(state.stream_states, key) do
      {:ok, {:text_buffer, buffer}} ->
        updated =
          case event do
            {:text, chunk} when is_binary(chunk) ->
              {:text_buffer, buffer <> chunk}

            {:action, payload} when is_map(payload) ->
              {:text_buffer, append_action_text(buffer, payload)}

            {:approval_request, payload} when is_map(payload) ->
              {:text_buffer, append_action_text(buffer, payload)}

            _ ->
              {:text_buffer, buffer}
          end

        {:noreply, put_in(state.stream_states[key], updated)}

      {:ok, {:channel_stream, spec, stream_state}} ->
        case spec.handle_stream_event(stream_state, event, parent: self(), key: key) do
          {:ok, updated} ->
            {:noreply, put_in(state.stream_states[key], {:channel_stream, spec, updated})}

          {:error, reason} ->
            Logger.warning("[InboundWorker] channel stream event failed: #{inspect(reason)}")
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:flush_feishu_stream, key}, state) do
    handle_channel_stream_timer(key, :flush, state)
  end

  @impl true
  def handle_info({:flush_discord_stream, key}, state) do
    handle_channel_stream_timer(key, :flush, state)
  end

  @impl true
  def handle_info({:channel_stream_timer, key, timer}, state) do
    handle_channel_stream_timer(key, timer, state)
  end

  @impl true
  def handle_info({:drain_queued_owner_run, key}, state) do
    if task_running?(state, key) do
      {:noreply, state}
    else
      {:noreply, maybe_drain_pending(state, key)}
    end
  end

  @impl true
  def handle_info({:discord_thinking_tick, key}, state) do
    handle_channel_stream_timer(key, :thinking, state)
  end

  @impl true
  def handle_info({:discord_typing_tick, key}, state) do
    handle_channel_stream_timer(key, :typing, state)
  end

  @impl true
  def handle_info({:discord_status_tick, key}, state) do
    handle_channel_stream_timer(key, :status, state)
  end

  @impl true
  def handle_info({:discord_follow_up_typing_tick, key}, state) do
    handle_info({:channel_follow_up_typing_tick, key}, state)
  end

  @impl true
  def handle_info({:channel_follow_up_typing_tick, key}, state) do
    case Map.get(state.active_follow_ups, key) do
      %{session_key: session_key} = entry ->
        cancel_follow_up_typing_timer(entry)
        {channel, chat_id} = parse_session_key(session_key)
        timer_ref = channel_follow_up_typing_timer(state.config, key, channel, chat_id)

        {:noreply, put_in(state.active_follow_ups[key], %{entry | typing_timer_ref: timer_ref})}

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

    observe_inbound_received(envelope, workspace, session_key, content)

    Logger.info(
      "InboundWorker received channel=#{channel} chat_id=#{chat_id} workspace=#{workspace} cmd=#{inspect(cmd)}"
    )

    with false <- empty_inbound?(cmd, envelope),
         {:command, %Invocation{} = invocation, definition} when is_map(definition) <-
           resolve_command(envelope, workspace, state.config) do
      dispatch_command(state, key, session_key, workspace, envelope, invocation, definition)
    else
      true ->
        state

      :no_match ->
        maybe_dispatch_prompt(state, key, session_key, workspace, content, envelope)

      {:command, _invocation, nil} ->
        maybe_dispatch_prompt(state, key, session_key, workspace, content, envelope)
    end
  end

  defp empty_inbound?(cmd, %Envelope{} = envelope) do
    cmd == "" and (envelope.media_refs || []) == [] and (envelope.attachments || []) == []
  end

  defp resolve_command(%Envelope{} = envelope, workspace, %Config{} = config) do
    definitions = runtime_command_definitions(workspace)
    channel_type = Config.channel_type(config, envelope.channel)

    typed_envelope =
      if is_binary(channel_type) and channel_type != "" do
        %{envelope | channel: channel_type}
      else
        envelope
      end

    case Command.resolve(typed_envelope, definitions) do
      :no_match -> Command.resolve(envelope, definitions)
      {:command, invocation, definition} -> {:command, invocation, definition}
    end
  end

  defp dispatch_command(
         state,
         key,
         session_key,
         workspace,
         %Envelope{} = envelope,
         %Invocation{} = invocation,
         definition
       ) do
    bypass_busy? = Map.get(definition, "bypass_busy?", false) == true

    if task_running?(state, key) and not bypass_busy? do
      maybe_dispatch_prompt(state, key, session_key, workspace, invocation.raw, envelope)
    else
      case Map.get(definition, "handler") do
        "new" -> handle_new_command(state, key, session_key, workspace, envelope)
        "stop" -> handle_stop_command(state, key, session_key, workspace, envelope)
        "approve" -> handle_approve_command(state, session_key, workspace, invocation, envelope)
        "deny" -> handle_deny_command(state, session_key, workspace, invocation, envelope)
        "commands" -> handle_commands_command(state, envelope)
        "status" -> handle_status_command(state, session_key, workspace, envelope)
        "model" -> handle_model_command(state, key, session_key, workspace, invocation, envelope)
        "queue" -> handle_queue_command(state, key, session_key, workspace, invocation, envelope)
        "btw" -> handle_btw_command(state, session_key, workspace, invocation, envelope)
        _ -> maybe_dispatch_prompt(state, key, session_key, workspace, invocation.raw, envelope)
      end
    end
  end

  defp handle_new_command(state, key, session_key, workspace, %Envelope{} = envelope) do
    state = cancel_follow_up_task(state, key)
    state = cancel_active_task(state, key, session_key, workspace, :new_session)
    approval_reset_session(workspace, session_key, :new)
    reset_current_session(session_key, workspace)
    publish_outbound(envelope, "New session started.")

    %{
      state
      | agents: Map.delete(state.agents, key),
        pending_queue: Map.delete(state.pending_queue, key)
    }
  end

  defp reset_current_session(session_key, workspace) do
    session_key
    |> SessionManager.get_or_create(workspace: workspace)
    |> Session.clear()
    |> Session.clear_model_override()
    |> SessionManager.save_sync(workspace: workspace)

    :ok
  end

  defp handle_stop_command(state, key, session_key, workspace, %Envelope{} = envelope) do
    {{:ok, %{cancelled?: cancelled?, count: count}}, state} =
      request_interrupt_local(state, key, session_key, workspace, :user_stop)

    _ = cancelled?

    dropped = :queue.len(Map.get(state.pending_queue, key, :queue.new()))
    state = %{state | pending_queue: Map.delete(state.pending_queue, key)}
    state = update_queue_count(state, key, 0)
    approval_cancel_pending(workspace, session_key, :stop)

    observe_queue_changed(
      workspace,
      session_key,
      envelope.channel,
      envelope.chat_id,
      "drop",
      0,
      dropped
    )

    publish_outbound(
      envelope,
      "Stopped #{count} task(s)#{if dropped > 0, do: ", dropped #{dropped} queued message(s)", else: ""}."
    )

    state
  end

  defp handle_approve_command(
         state,
         session_key,
         workspace,
         %Invocation{} = invocation,
         %Envelope{} = envelope
       ) do
    result =
      with {:ok, {request_id, choice}} <- approve_choice(invocation.args),
           {:ok, approval_result} <-
             approval_call(:approve, workspace, session_key, request_id, choice, envelope) do
        {:ok, approval_result}
      end

    publish_outbound(envelope, render_approve_result(result))
    state
  end

  defp handle_deny_command(
         state,
         session_key,
         workspace,
         %Invocation{} = invocation,
         %Envelope{} = envelope
       ) do
    result =
      with {:ok, {request_id, choice}} <- deny_choice(invocation.args),
           {:ok, deny_result} <-
             approval_call(:deny, workspace, session_key, request_id, choice, envelope) do
        {:ok, deny_result}
      end

    publish_outbound(envelope, render_deny_result(result))
    state
  end

  defp approve_choice(args) do
    {request_id, rest} = split_approval_request_id(args)

    case rest do
      [] -> {:ok, {request_id, :once}}
      ["all" | _rest] when is_nil(request_id) -> {:ok, {nil, :all}}
      ["session" | _rest] -> {:ok, {request_id, :session}}
      ["similar" | _rest] -> {:ok, {request_id, :similar}}
      ["always" | _rest] -> {:ok, {request_id, :always}}
      _args -> {:error, :approve_usage}
    end
  end

  defp deny_choice(args) do
    {request_id, rest} = split_approval_request_id(args)

    case rest do
      [] -> {:ok, {request_id, :once}}
      ["all" | _rest] when is_nil(request_id) -> {:ok, {nil, :all}}
      _args -> {:error, :deny_usage}
    end
  end

  defp split_approval_request_id(args) when is_list(args) do
    case Enum.split_with(args, &approval_request_id?/1) do
      {[request_id], rest} -> {request_id, rest}
      {[], rest} -> {nil, rest}
      _other -> {nil, ["invalid"]}
    end
  end

  defp split_approval_request_id(_args), do: {nil, ["invalid"]}

  defp approval_request_id?(value) when is_binary(value),
    do: String.starts_with?(value, "approval_")

  defp approval_request_id?(_value), do: false

  defp approval_call(
         :approve,
         _workspace,
         _session_key,
         request_id,
         choice,
         %Envelope{} = envelope
       )
       when is_binary(request_id) do
    if Process.whereis(Approval) do
      Approval.approve_request(request_id, choice, authorized_actor: approval_actor(envelope))
    else
      {:error, :approval_unavailable}
    end
  end

  defp approval_call(:approve, workspace, session_key, nil, choice, %Envelope{} = envelope) do
    if Process.whereis(Approval) do
      Approval.approve(workspace, session_key, choice, authorized_actor: approval_actor(envelope))
    else
      {:error, :approval_unavailable}
    end
  end

  defp approval_call(:deny, _workspace, _session_key, request_id, choice, %Envelope{} = envelope)
       when is_binary(request_id) do
    if Process.whereis(Approval) do
      Approval.deny_request(request_id, choice, authorized_actor: approval_actor(envelope))
    else
      {:error, :approval_unavailable}
    end
  end

  defp approval_call(:deny, workspace, session_key, nil, choice, %Envelope{} = envelope) do
    if Process.whereis(Approval) do
      Approval.deny(workspace, session_key, choice, authorized_actor: approval_actor(envelope))
    else
      {:error, :approval_unavailable}
    end
  end

  defp approval_actor(%Envelope{} = envelope) do
    %{
      "sender_id" => envelope.sender_id,
      "user_id" => envelope.user_id,
      "channel" => envelope.channel,
      "chat_id" => payload_chat_id(envelope)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp render_approve_result({:ok, %{approved: 0}}), do: "No pending approval requests."

  defp render_approve_result({:ok, %{approved: count, choice: :all}}) do
    "Approved #{count} pending request(s)."
  end

  defp render_approve_result({:ok, %{approved: count, granted: nil}}) do
    "Approved #{count} pending request(s)."
  end

  defp render_approve_result({:ok, %{approved: count, granted: %{} = grant}}) do
    scope = Map.get(grant, "scope", "session")
    "Approved #{count} pending request(s) and granted #{scope} permission."
  end

  defp render_approve_result({:error, :approve_usage}) do
    "Usage: /approve [request_id] [session|similar|always] or /approve all"
  end

  defp render_approve_result({:error, :approval_unavailable}),
    do: "Approval service is unavailable."

  defp render_approve_result({:error, :no_pending_request}), do: "No pending approval requests."

  defp render_approve_result({:error, :no_similar_grant_option}) do
    "No similar safe grant is available for the pending request."
  end

  defp render_approve_result({:error, reason}), do: "Approval failed: #{inspect(reason)}"

  defp render_deny_result({:ok, %{denied: 0}}), do: "No pending approval requests."

  defp render_deny_result({:ok, %{denied: count}}) do
    "Denied #{count} pending request(s)."
  end

  defp render_deny_result({:error, :deny_usage}), do: "Usage: /deny [request_id] or /deny all"
  defp render_deny_result({:error, :approval_unavailable}), do: "Approval service is unavailable."
  defp render_deny_result({:error, :no_pending_request}), do: "No pending approval requests."
  defp render_deny_result({:error, reason}), do: "Deny failed: #{inspect(reason)}"

  defp approval_reset_session(workspace, session_key, reason) do
    if Process.whereis(Approval) do
      _ = Approval.reset_session(workspace, session_key, reason)
    end

    :ok
  end

  defp approval_cancel_pending(workspace, session_key, reason) do
    if Process.whereis(Approval) do
      _ = Approval.cancel_pending(workspace, session_key, reason)
    end

    :ok
  end

  defp handle_commands_command(state, %Envelope{} = envelope) do
    commands = commands_for_channel(envelope.channel, payload_workspace(envelope), state.config)
    publish_outbound(envelope, render_commands_help(commands))
    state
  end

  defp handle_status_command(state, session_key, workspace, %Envelope{} = envelope) do
    observe_status_requested(envelope, workspace, session_key)
    config = config_for_workspace(workspace, state.config)
    session = SessionManager.get_or_create(session_key, workspace: workspace)

    case RunControl.owner_snapshot(workspace, session_key) do
      {:ok, run} ->
        publish_outbound(
          envelope,
          StatusView.render_status(config, session, run, status_evidence(run),
            workspace: workspace
          )
        )

      {:error, :idle} ->
        publish_outbound(
          envelope,
          StatusView.render_status(config, session, nil, status_evidence(workspace, session_key),
            workspace: workspace
          )
        )
    end

    state
  end

  defp handle_model_command(
         state,
         key,
         session_key,
         workspace,
         %Invocation{} = invocation,
         %Envelope{} = envelope
       ) do
    config = config_for_workspace(workspace, state.config)
    session = SessionManager.get_or_create(session_key, workspace: workspace)
    arg = invocation.args |> Enum.join(" ") |> String.trim()

    cond do
      arg == "" ->
        publish_outbound(envelope, StatusView.render_model(config, session))
        state

      arg in ["reset", "default"] ->
        session =
          session
          |> Session.clear_model_override()
          |> SessionManager.save_sync(workspace: workspace)

        publish_outbound(envelope, StatusView.render_model_reset(config, session))
        %{state | agents: Map.delete(state.agents, key)}

      true ->
        case StatusView.resolve_model_ref(config, session, arg) do
          {:ok, entry} ->
            session
            |> Session.put_model_override(entry.key)
            |> SessionManager.save_sync(workspace: workspace)

            publish_outbound(envelope, StatusView.render_model_switched(entry))
            %{state | agents: Map.delete(state.agents, key)}

          {:error, :unknown_model, entries} ->
            publish_outbound(envelope, StatusView.render_unknown_model(arg, entries))
            state
        end
    end
  end

  defp handle_queue_command(
         state,
         key,
         session_key,
         workspace,
         %Invocation{} = invocation,
         %Envelope{} = envelope
       ) do
    message = invocation.args |> Enum.join(" ") |> String.trim()

    if message == "" do
      publish_outbound(envelope, "Usage: /queue <message>")
      state
    else
      queued_envelope = %{envelope | text: message}

      queue =
        state.pending_queue
        |> Map.get(key, :queue.new())
        |> then(&:queue.in({session_key, workspace, message, queued_envelope}, &1))

      state = %{state | pending_queue: Map.put(state.pending_queue, key, queue)}
      state = update_queue_count(state, key, :queue.len(queue))

      observe_queue_changed(
        workspace,
        session_key,
        envelope.channel,
        envelope.chat_id,
        "enqueue",
        :queue.len(queue),
        0
      )

      unless task_running?(state, key) do
        send(self(), {:drain_queued_owner_run, key})
      end

      publish_outbound(envelope, "Queued for next owner turn (#{:queue.len(queue)} queued).")
      state
    end
  end

  defp handle_btw_command(
         state,
         session_key,
         workspace,
         %Invocation{} = invocation,
         %Envelope{} = envelope
       ) do
    question = invocation.args |> Enum.join(" ") |> String.trim()

    cond do
      question == "" ->
        publish_outbound(envelope, "Usage: /btw <message>")
        state

      true ->
        dispatch_follow_up(state, session_key, workspace, question, envelope)
    end
  end

  defp maybe_dispatch_prompt(state, key, session_key, workspace, content, envelope) do
    if task_running?(state, key) do
      dispatch_follow_up(state, session_key, workspace, content, envelope)
    else
      dispatch_async(state, key, session_key, workspace, content, envelope)
    end
  end

  defp dispatch_follow_up(state, session_key, workspace, question, %Envelope{} = envelope) do
    key = runtime_key(workspace, session_key)
    state = cancel_follow_up_task(state, key)

    {:ok, agent, state} =
      ensure_agent(state, key, session_key, workspace)

    owner_snapshot =
      case RunControl.owner_snapshot(workspace, session_key) do
        {:ok, run} -> run
        {:error, :idle} -> nil
      end

    mode = if owner_snapshot, do: :busy, else: :idle

    parent = self()
    {channel, chat_id} = parse_session_key(session_key)
    metadata = extract_metadata(envelope)

    observe_follow_up("inbound.follow_up.started", :info, envelope, %{
      "mode" => Atom.to_string(mode)
    })

    {:ok, pid} =
      Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
        {prompt_envelope, prompt_question} =
          hydrate_inbound_media_for_prompt(envelope, question,
            workspace: workspace,
            session_key: session_key,
            channel: channel,
            chat_id: chat_id
          )

        prompt =
          FollowUp.prompt(owner_snapshot, prompt_question,
            mode: mode,
            workspace: workspace,
            session_key: session_key
          )

        result =
          run_prompt_task(
            state.agent_prompt_fun,
            agent,
            prompt,
            channel: channel,
            chat_id: chat_id,
            workspace: workspace,
            skip_consolidation: true,
            tools_filter: :follow_up,
            schedule_memory_refresh: false,
            skip_skills: true,
            media: prompt_envelope.attachments,
            parent_chat_id: Map.get(metadata, "parent_chat_id"),
            metadata:
              metadata
              |> Map.new()
              |> Map.put("_follow_up", true)
              |> Map.put("follow_up_question", prompt_question)
              |> Map.put("follow_up_mode", Atom.to_string(mode))
          )

        send(parent, {:follow_up_result, key, self(), result, prompt_envelope})
      end)

    Process.monitor(pid)
    typing_timer_ref = start_channel_follow_up_typing_timer(state.config, key, channel, chat_id)

    put_in(state.active_follow_ups[key], %{
      pid: pid,
      workspace: workspace,
      session_key: session_key,
      typing_timer_ref: typing_timer_ref
    })
  end

  defp dispatch_async(state, key, session_key, workspace, content, %Envelope{} = envelope) do
    {channel, chat_id} = parse_session_key(session_key)

    # Notify channels that we've acknowledged the inbound message
    Bus.publish(:inbound_ack, %{
      channel: channel,
      chat_id: chat_id,
      message_id: Map.get(envelope.metadata, "message_id"),
      origin_channel_id: Map.get(envelope.metadata, "origin_channel_id"),
      envelope_message_id: envelope.message_id
    })

    {:ok, run} = start_owner_run(workspace, session_key, channel, chat_id)
    _ = RunControl.set_queued_count(run.id, queued_count(state, key))
    _ = RunControl.set_phase(run.id, :llm)

    observe_owner_dispatch("inbound.owner.dispatch.started", :info, envelope, run.id, %{
      "queued_count" => queued_count(state, key)
    })

    {:ok, agent, state} = ensure_agent(state, key, session_key, workspace)
    parent = self()
    from_cron = get_in(envelope.metadata, ["_from_cron"]) == true
    metadata = extract_metadata(envelope)
    stream_key = stream_key(key, run.id)

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

    {:ok, pid} =
      Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
        stream_sink =
          if from_cron do
            nil
          else
            build_stream_sink(parent, stream_key, channel, chat_id, envelope, state.config)
          end

        {prompt_envelope, prompt_content} =
          hydrate_inbound_media_for_prompt(envelope, content,
            workspace: workspace,
            run_id: run.id,
            cancel_ref: run.cancel_ref,
            session_key: session_key,
            channel: channel,
            chat_id: chat_id
          )

        result =
          run_prompt_task(
            state.agent_prompt_fun,
            agent,
            prompt_content,
            [
              channel: channel,
              chat_id: chat_id,
              stream_sink: stream_sink,
              run_id: run.id,
              owner_run_id: run.id,
              cancel_ref: run.cancel_ref,
              workspace: workspace,
              parent_chat_id: Map.get(metadata, "parent_chat_id"),
              schedule_memory_refresh: false
            ]
            |> maybe_put_opt(:media, prompt_envelope.attachments)
            |> Kernel.++(cron_opts)
          )

        send(parent, {:async_result, key, run.id, result, prompt_envelope})
      end)

    Process.monitor(pid)
    Process.send_after(self(), {:check_timeout, key, pid}, 600_000)

    %{
      state
      | active_tasks:
          Map.put(state.active_tasks, key, %{
            pid: pid,
            run_id: run.id,
            workspace: workspace,
            session_key: session_key
          }),
        agent_last_active: Map.put(state.agent_last_active, key, System.system_time(:second))
    }
  end

  defp start_channel_follow_up_typing_timer(config, key, channel, chat_id) do
    runtime = config_channel_runtime(config, channel)

    if Nex.Agent.Interface.Channel.Registry.whereis(channel) do
      case channel_spec_for_runtime(runtime, config) do
        {:ok, spec} ->
          if function_exported?(spec, :start_follow_up_typing, 3) do
            spec.start_follow_up_typing(channel, chat_id, parent: self(), key: key)
          end

        _ ->
          nil
      end
    end
  end

  defp channel_follow_up_typing_timer(config, key, channel, chat_id) do
    runtime = config_channel_runtime(config, channel)

    case channel_spec_for_runtime(runtime, config) do
      {:ok, spec} ->
        if function_exported?(spec, :handle_follow_up_typing, 3) do
          spec.handle_follow_up_typing(channel, chat_id, parent: self(), key: key)
        end

      _ ->
        nil
    end
  end

  defp build_stream_sink(parent, key, channel, chat_id, envelope, config) do
    metadata = extract_metadata(envelope)
    channel_runtime = channel_runtime(envelope, channel, config)
    streaming? = Map.get(channel_runtime, "streaming", false) == true

    cond do
      streaming? ->
        if Nex.Agent.Interface.Channel.Registry.whereis(channel) do
          case channel_spec_for_runtime(channel_runtime, config) do
            {:ok, spec} ->
              if function_exported?(spec, :start_stream, 4) do
                case spec.start_stream(channel, chat_id, metadata, parent: parent, key: key) do
                  {:ok, stream_state} ->
                    send(
                      parent,
                      {:stream_state_started, key, {:channel_stream, spec, stream_state}}
                    )

                    stream_sink(parent, key)

                  {:error, reason} ->
                    Logger.warning(
                      "[InboundWorker] channel stream start failed: #{inspect(reason)}"
                    )

                    nil

                  :ignore ->
                    nil
                end
              else
                text_buffer_stream_sink(parent, key)
              end

            _ ->
              text_buffer_stream_sink(parent, key)
          end
        else
          nil
        end

      true ->
        nil
    end
  end

  defp stream_sink(parent, key) do
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

      {:approval_request, payload} when is_map(payload) ->
        send(parent, {:stream_state_event, key, {:approval_request, payload}})
        :ok

      {:action, payload} when is_map(payload) ->
        send(parent, {:stream_state_event, key, {:action, payload}})
        :ok
    end
  end

  defp text_buffer_stream_sink(parent, key) do
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

      {:approval_request, payload} when is_map(payload) ->
        send(parent, {:stream_state_event, key, {:approval_request, payload}})
        :ok

      {:action, payload} when is_map(payload) ->
        send(parent, {:stream_state_event, key, {:action, payload}})
        :ok
    end
  end

  defp append_action_text(buffer, payload) do
    text = OutboundAction.fallback_content(payload)

    cond do
      text == "" ->
        buffer

      buffer == "" ->
        text <> "\n"

      String.ends_with?(buffer, "\n") ->
        buffer <> text <> "\n"

      true ->
        buffer <> "\n" <> text <> "\n"
    end
  end

  defp channel_spec_for_runtime(runtime, config) when is_map(runtime) do
    runtime
    |> Map.get("type")
    |> ChannelCatalog.fetch(channel_catalog_opts(config))
  end

  defp channel_spec_for_runtime(_runtime, _config), do: {:error, :unknown_channel_type}

  defp channel_catalog_opts(config) do
    case Runtime.current() do
      {:ok, %Snapshot{plugins: plugins}} ->
        [plugin_data: plugins, config: config]

      _ ->
        [config: config]
    end
  end

  defp channel_runtime(envelope, channel, config) do
    workspace = payload_workspace(envelope)
    fallback = config_channel_runtime(config, channel)

    case runtime_snapshot_for_workspace(workspace) do
      %Snapshot{workspace: snapshot_workspace, channels: channels}
      when is_map(channels) and is_binary(snapshot_workspace) ->
        if same_workspace?(snapshot_workspace, workspace) do
          fallback
        else
          Map.get(channels, to_string(channel), fallback)
        end

      %Snapshot{config: %Config{} = config} ->
        config_channel_runtime(config, channel)

      _ ->
        fallback
    end
  end

  defp config_channel_runtime(config, channel) do
    case Config.channel_runtime(config, channel) do
      {:ok, runtime} -> runtime
      {:error, _diagnostic} -> %{}
    end
  end

  defp maybe_drain_pending(state, key) do
    case Map.get(state.pending_queue, key) do
      nil ->
        update_queue_count(state, key, 0)

      queue ->
        state = update_queue_count(state, key, :queue.len(queue))

        case :queue.out(queue) do
          {{:value, {session_key, workspace, content, envelope}}, rest} ->
            remaining =
              if :queue.is_empty(rest),
                do: Map.delete(state.pending_queue, key),
                else: Map.put(state.pending_queue, key, rest)

            state = %{state | pending_queue: remaining}
            state = update_queue_count(state, key, :queue.len(rest))

            observe_queue_changed(
              workspace,
              session_key,
              envelope.channel,
              envelope.chat_id,
              "drain",
              :queue.len(rest),
              0
            )

            Logger.info(
              "[InboundWorker] Draining queued message for #{inspect(key)} (remaining=#{:queue.len(rest)})"
            )

            dispatch_async(state, key, session_key, workspace, content, envelope)

          {:empty, _} ->
            state
            |> Map.update!(:pending_queue, &Map.delete(&1, key))
            |> update_queue_count(key, 0)
        end
    end
  end

  defp cancel_active_task(state, key, session_key, workspace, reason) do
    case Map.get(state.active_tasks, key) do
      nil ->
        cancel_session_subagents(state, session_key, workspace)

      %{pid: pid, run_id: run_id} ->
        state
        |> cancel_owner_run(key, session_key, workspace, run_id, pid, reason)
        |> cancel_session_subagents(session_key, workspace)
    end
  end

  defp request_interrupt_impl(state, key, session_key, workspace, reason, requester_pid) do
    interrupted_run_id = current_run_id(state, key)

    follow_up_cancelled? =
      case Map.get(state.active_follow_ups, key) do
        %{pid: pid} when pid != requester_pid -> true
        _ -> false
      end

    {count, state} =
      case Map.get(state.active_tasks, key) do
        nil ->
          {0, state}

        %{pid: pid, run_id: run_id} ->
          {1, cancel_owner_run(state, key, session_key, workspace, run_id, pid, reason)}
      end

    subagent_count =
      if Process.whereis(Nex.Agent.Capability.Subagent) do
        {:ok, n} =
          Nex.Agent.Capability.Subagent.cancel_by_session(session_key, workspace: workspace)

        n
      else
        0
      end

    state = cancel_follow_up_task(state, key, requester_pid)
    state = abort_session_agent(state, key)

    total_count = count + subagent_count + if(follow_up_cancelled?, do: 1, else: 0)
    reply = {:ok, %{cancelled?: total_count > 0, run_id: interrupted_run_id, count: total_count}}
    observe_interrupt_requested(workspace, session_key, interrupted_run_id, reason, total_count)
    {reply, state}
  end

  defp request_interrupt_local(state, key, session_key, workspace, reason, requester_pid \\ nil) do
    request_interrupt_impl(state, key, session_key, workspace, reason, requester_pid)
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
          session =
            Nex.Agent.Conversation.SessionManager.get_or_create(session_key, workspace: workspace)

          updated_agent = %{agent | session: session, workspace: workspace}
          {:ok, updated_agent, put_in(state.agents[key], updated_agent)}
        end

      :error ->
        opts = agent_start_opts(session_key, workspace, state.config)

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

  defp agent_start_opts(session_key, workspace, fallback_config) do
    [channel, chat_id] = String.split(session_key, ":", parts: 2)
    snapshot = runtime_snapshot_for_workspace(workspace)
    config = config_for_workspace(workspace, fallback_config)
    session = SessionManager.get_or_create(session_key, workspace: workspace)
    model_runtime = StatusView.model_runtime_for_session(config, session)
    home = System.get_env("HOME", File.cwd!())

    [
      provider: model_runtime && model_runtime.provider,
      model: model_runtime && model_runtime.model_id,
      api_key: model_runtime && model_runtime.api_key,
      base_url: model_runtime && model_runtime.base_url,
      model_runtime: model_runtime,
      provider_options: model_runtime && model_runtime.provider_options,
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

  defp config_for_workspace(workspace, fallback_config) do
    case runtime_snapshot_for_workspace(workspace) do
      %Snapshot{config: %Config{} = config} -> config
      _ -> fallback_config
    end
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

  defp commands_for_channel(channel, workspace, %Config{} = config) do
    snapshot = runtime_snapshot_for_workspace(workspace)
    channel_keys = command_channel_keys(channel, snapshot, config)

    snapshot
    |> runtime_command_definitions()
    |> Enum.filter(fn definition ->
      channels = Map.get(definition, "channels", [])
      channels == [] or Enum.any?(channel_keys, &(&1 in channels))
    end)
  end

  defp command_channel_keys(channel, %Snapshot{config: %Config{} = config}, _fallback_config) do
    [to_string(channel), Config.channel_type(config, channel)]
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp command_channel_keys(channel, _snapshot, %Config{} = config) do
    [to_string(channel), Config.channel_type(config, channel)]
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp command_channel_keys(channel, _snapshot, _config), do: [to_string(channel)]

  defp runtime_command_definitions(%Snapshot{commands: %{definitions: definitions}})
       when is_list(definitions) and definitions != [] do
    definitions
  end

  defp runtime_command_definitions(_snapshot) do
    case Runtime.current() do
      {:ok, %Snapshot{commands: %{definitions: definitions}}}
      when is_list(definitions) and definitions != [] ->
        definitions

      _ ->
        Nex.Agent.Conversation.Command.Catalog.runtime_definitions()
    end
  end

  defp render_commands_help([]), do: "No slash commands are available in this chat."

  defp render_commands_help(definitions) do
    body =
      definitions
      |> Enum.map(fn definition ->
        usage = Map.get(definition, "usage", "/#{Map.get(definition, "name", "unknown")}")
        description = Map.get(definition, "description", "")
        "#{usage} - #{description}"
      end)
      |> Enum.join("\n")

    "Available slash commands:\n" <> body
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

  defp maybe_enqueue_memory_refresh(_agent, _payload, true, _from_subagent, _prompt_fun, _config),
    do: :ok

  defp maybe_enqueue_memory_refresh(_agent, _payload, _from_cron, true, _prompt_fun, _config),
    do: :ok

  defp maybe_enqueue_memory_refresh(
         %Nex.Agent{} = agent,
         payload,
         false,
         false,
         prompt_fun,
         config
       ) do
    if memory_refresh_allowed?(agent, prompt_fun) do
      enqueue_memory_refresh(agent, payload, config)
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

  defp enqueue_memory_refresh(%Nex.Agent{} = agent, payload, config) do
    runtime = memory_refresh_runtime(config, agent)

    MemoryUpdater.enqueue(
      agent.session,
      provider: runtime.provider,
      model: runtime.model,
      api_key: runtime.api_key,
      base_url: runtime.base_url,
      provider_options: runtime.provider_options,
      workspace: agent.workspace,
      channel: payload.channel,
      chat_id: payload_chat_id(payload),
      model_role: runtime.model_role,
      notify_memory_updates: true,
      source: "owner_run"
    )
  end

  defp memory_refresh_runtime(%Config{} = config, %Nex.Agent{} = agent) do
    case Config.memory_model_runtime(config) do
      %{provider: provider, model_id: model} = runtime ->
        %{
          provider: provider,
          model: model,
          api_key: runtime.api_key,
          base_url: runtime.base_url,
          provider_options: runtime.provider_options,
          model_role: "memory"
        }

      _ ->
        %{
          provider: agent.provider,
          model: agent.model,
          api_key: agent.api_key,
          base_url: agent.base_url,
          provider_options: agent.provider_options || [],
          model_role: "runtime"
        }
    end
  end

  defp memory_refresh_runtime(_config, %Nex.Agent{} = agent) do
    %{
      provider: agent.provider,
      model: agent.model,
      api_key: agent.api_key,
      base_url: agent.base_url,
      provider_options: agent.provider_options || [],
      model_role: "runtime"
    }
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

  defp empty_content?(%Result{final_content: content}), do: empty_string?(content)
  defp empty_content?(content) when is_binary(content), do: empty_string?(content)
  defp empty_content?(_), do: true

  defp empty_string?(nil), do: true
  defp empty_string?(s) when is_binary(s), do: String.trim(s) == ""
  defp empty_string?(_), do: false

  defp handle_channel_stream_timer(key, timer, state) do
    case Map.fetch(state.stream_states, key) do
      {:ok, {:channel_stream, spec, stream_state}} ->
        if function_exported?(spec, :handle_stream_timer, 3) do
          case spec.handle_stream_timer(stream_state, timer, parent: self(), key: key) do
            {:ok, updated} ->
              {:noreply, put_in(state.stream_states[key], {:channel_stream, spec, updated})}

            {:error, reason} ->
              Logger.warning("[InboundWorker] channel stream timer failed: #{inspect(reason)}")
              {:noreply, state}
          end
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp finalize_stream_session(state, key, result) do
    case Map.fetch(state.stream_states, key) do
      {:ok, {:text_buffer, buffer}} ->
        handled? =
          case result do
            {:ok, _value} when is_binary(buffer) and buffer != "" ->
              {channel, chat_id} =
                key
                |> stream_runtime_key()
                |> elem(1)
                |> parse_session_key()

              Bus.publish(Outbound.topic_for_channel(channel), %{
                chat_id: chat_id,
                content: buffer,
                metadata: %{}
              })

              true

            _ ->
              false
          end

        {%{state | stream_states: Map.delete(state.stream_states, key)}, handled?}

      {:ok, {:channel_stream, spec, stream_state}} ->
        case spec.finalize_stream(stream_state, result, parent: self(), key: key) do
          :ok ->
            {%{state | stream_states: Map.delete(state.stream_states, key)}, true}

          {:ok, _updated} ->
            {%{state | stream_states: Map.delete(state.stream_states, key)}, true}

          {:error, reason} ->
            Logger.warning("[InboundWorker] channel stream finalize failed: #{inspect(reason)}")
            {%{state | stream_states: Map.delete(state.stream_states, key)}, true}
        end

      :error ->
        {state, false}
    end
  end

  defp normalize_inbound_content(content) when is_binary(content), do: content
  defp normalize_inbound_content(nil), do: ""
  defp normalize_inbound_content(content), do: inspect(content, printable_limit: 500, limit: 50)

  defp hydrate_inbound_media_for_prompt(%Envelope{} = envelope, content, opts) do
    refs = envelope.media_refs || []

    if refs == [] do
      {envelope, content}
    else
      {attachments, unresolved_refs} =
        Hydrator.hydrate_refs(refs,
          workspace: Keyword.get(opts, :workspace),
          fetch_binary_fun: &fetch_inbound_media_binary(&1, opts)
        )

      envelope = %{
        envelope
        | attachments: (envelope.attachments || []) ++ attachments,
          media_refs: unresolved_refs
      }

      {envelope, append_unresolved_media_notice(content, unresolved_refs)}
    end
  end

  defp fetch_inbound_media_binary(
         %Ref{platform_ref: %{"url" => url}, metadata: metadata} = ref,
         opts
       )
       when is_binary(url) and url != "" do
    with :ok <- ensure_inbound_media_size(metadata),
         {:ok, response} <-
           HTTP.get(url,
             receive_timeout: 30_000,
             cancel_ref: Keyword.get(opts, :cancel_ref),
             observe_context: http_observe_context(opts)
           ),
         {:ok, body, mime_type} <- extract_inbound_media_response(response, ref) do
      ensure_inbound_media_body_size(body)
      |> case do
        :ok -> {:ok, body, mime_type}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_inbound_media_binary(%Ref{}, _opts), do: :unhandled

  defp ensure_inbound_media_size(metadata) when is_map(metadata) do
    case Map.get(metadata, "size") || Map.get(metadata, :size) do
      size when is_integer(size) and size > @max_inbound_attachment_bytes ->
        {:error, {:attachment_too_large, size, @max_inbound_attachment_bytes}}

      _ ->
        :ok
    end
  end

  defp ensure_inbound_media_size(_metadata), do: :ok

  defp ensure_inbound_media_body_size(body)
       when byte_size(body) > @max_inbound_attachment_bytes do
    {:error, {:attachment_too_large, byte_size(body), @max_inbound_attachment_bytes}}
  end

  defp ensure_inbound_media_body_size(_body), do: :ok

  defp extract_inbound_media_response(
         %{status: status, body: body} = response,
         %Ref{} = ref
       )
       when status in 200..299 and is_binary(body) do
    {:ok, body, response_content_type(response) || ref.mime_type}
  end

  defp extract_inbound_media_response(%{status: status}, _ref),
    do: {:error, {:http_status, status}}

  defp extract_inbound_media_response(response, %Ref{} = ref) when is_binary(response) do
    {:ok, response, ref.mime_type}
  end

  defp extract_inbound_media_response({:error, reason}, _ref), do: {:error, reason}
  defp extract_inbound_media_response(_response, _ref), do: {:error, :invalid_response}

  defp response_content_type(%{headers: headers}), do: header_value(headers, "content-type")
  defp response_content_type(%{"headers" => headers}), do: header_value(headers, "content-type")
  defp response_content_type(_response), do: nil

  defp header_value(headers, name) when is_list(headers) do
    name = String.downcase(name)

    headers
    |> Enum.find_value(fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == name, do: value

      {key, value} when is_atom(key) ->
        if key |> Atom.to_string() |> String.downcase() == name, do: value

      _other ->
        nil
    end)
    |> normalize_header_value()
  end

  defp header_value(headers, name) when is_map(headers) do
    headers
    |> Map.get(name, Map.get(headers, String.downcase(name)))
    |> normalize_header_value()
  end

  defp header_value(_headers, _name), do: nil

  defp normalize_header_value([value | _rest]), do: normalize_header_value(value)
  defp normalize_header_value(value) when is_binary(value), do: value |> String.split(";") |> hd()
  defp normalize_header_value(_value), do: nil

  defp append_unresolved_media_notice(content, unresolved_refs) do
    case Projector.unresolved_refs_text(unresolved_refs) do
      nil ->
        content

      notice ->
        [content, notice]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n\n")
    end
  end

  defp http_observe_context(opts) do
    %{
      workspace: Keyword.get(opts, :workspace),
      run_id: Keyword.get(opts, :run_id),
      session_key: Keyword.get(opts, :session_key),
      channel: Keyword.get(opts, :channel),
      chat_id: Keyword.get(opts, :chat_id)
    }
  end

  defp observe_inbound_received(%Envelope{} = envelope, workspace, session_key, content) do
    observe_log(
      :info,
      "inbound.message.received",
      %{
        "message_type" => Atom.to_string(envelope.message_type || :unknown),
        "message_preview" => preview_text(content),
        "has_attachments" => envelope.attachments != [],
        "media_ref_count" => length(envelope.media_refs || [])
      },
      workspace: workspace,
      session_key: session_key,
      channel: envelope.channel,
      chat_id: payload_chat_id(envelope)
    )
  end

  defp observe_owner_dispatch(tag, level, %Envelope{} = envelope, run_id, attrs) do
    workspace = payload_workspace(envelope)
    session_key = session_key(envelope.channel, payload_chat_id(envelope))

    observe_log(
      level,
      tag,
      attrs,
      workspace: workspace,
      run_id: run_id,
      session_key: session_key,
      channel: envelope.channel,
      chat_id: payload_chat_id(envelope)
    )
  end

  defp observe_owner_timeout(state, key) do
    case Map.get(state.active_tasks, key) do
      %{run_id: run_id, workspace: workspace, session_key: session_key} ->
        {channel, chat_id} = parse_session_key(session_key)

        observe_log(
          :error,
          "inbound.owner.dispatch.timeout",
          %{"result_status" => "timeout", "reason_type" => "timeout"},
          workspace: workspace,
          run_id: run_id,
          session_key: session_key,
          channel: channel,
          chat_id: chat_id
        )

      _ ->
        :ok
    end
  end

  defp observe_owner_process_exit(workspace, session_key, run_id, reason) do
    {channel, chat_id} = parse_session_key(session_key)

    observe_log(
      :error,
      "inbound.owner.dispatch.failed",
      error_attrs(reason),
      workspace: workspace,
      run_id: run_id,
      session_key: session_key,
      channel: channel,
      chat_id: chat_id
    )
  end

  defp observe_follow_up(tag, level, %Envelope{} = envelope, attrs) do
    workspace = payload_workspace(envelope)
    session_key = session_key(envelope.channel, payload_chat_id(envelope))

    observe_log(
      level,
      tag,
      attrs,
      workspace: workspace,
      session_key: session_key,
      channel: envelope.channel,
      chat_id: payload_chat_id(envelope)
    )
  end

  defp observe_follow_up_exit(_key, %{workspace: workspace, session_key: session_key}, reason) do
    {channel, chat_id} = parse_session_key(session_key)

    observe_log(
      :error,
      "inbound.follow_up.failed",
      error_attrs(reason),
      workspace: workspace,
      session_key: session_key,
      channel: channel,
      chat_id: chat_id
    )
  end

  defp observe_queue_changed(
         workspace,
         session_key,
         channel,
         chat_id,
         action,
         queued_count,
         dropped_count
       ) do
    observe_log(
      :info,
      "inbound.queue.changed",
      %{
        "action" => action,
        "queued_count" => queued_count,
        "dropped_count" => dropped_count
      },
      workspace: workspace,
      session_key: session_key,
      channel: channel,
      chat_id: to_string(chat_id)
    )
  end

  defp observe_interrupt_requested(workspace, session_key, run_id, reason, count) do
    {channel, chat_id} = parse_session_key(session_key)

    observe_log(
      :warning,
      "inbound.interrupt.requested",
      %{
        "run_id" => run_id,
        "reason_type" => reason_type(reason),
        "cancelled_count" => count
      },
      workspace: workspace,
      run_id: run_id,
      session_key: session_key,
      channel: channel,
      chat_id: chat_id
    )
  end

  defp observe_status_requested(%Envelope{} = envelope, workspace, session_key) do
    observe_log(
      :info,
      "inbound.status.requested",
      %{},
      workspace: workspace,
      session_key: session_key,
      channel: envelope.channel,
      chat_id: payload_chat_id(envelope)
    )
  end

  defp observe_log(level, tag, attrs, opts) do
    attrs = attrs |> compact_attrs() |> Redactor.redact()

    _ =
      case level do
        :error -> Nex.Agent.Observe.ControlPlane.Log.error(tag, attrs, opts)
        :warning -> Nex.Agent.Observe.ControlPlane.Log.warning(tag, attrs, opts)
        _ -> Nex.Agent.Observe.ControlPlane.Log.info(tag, attrs, opts)
      end

    :ok
  rescue
    e ->
      Logger.warning("[InboundWorker] #{tag} observation failed: #{Exception.message(e)}")
      :ok
  end

  defp status_evidence(%RunControl.Run{} = run) do
    status_evidence(run.workspace, run.session_key, run.id)
  end

  defp status_evidence(workspace, session_key, run_id \\ nil) do
    filters =
      %{"session_key" => session_key, "limit" => 50}
      |> maybe_put_filter("run_id", run_id)

    warnings_or_errors =
      filters
      |> Query.query(workspace: workspace)
      |> Enum.filter(&(&1["level"] in ["warning", "error", "critical"]))

    latest = List.last(warnings_or_errors)

    "Evidence: recent warnings/errors=#{length(warnings_or_errors)}" <>
      latest_evidence_suffix(latest)
  end

  defp latest_evidence_suffix(nil), do: ""

  defp latest_evidence_suffix(observation) do
    tag = Map.get(observation, "tag", "unknown")

    summary =
      observation
      |> get_in(["attrs", "summary"])
      |> case do
        value when is_binary(value) and value != "" -> value
        _ -> get_in(observation, ["attrs", "reason_type"]) || "-"
      end
      |> to_string()
      |> String.slice(0, 200)

    " latest=#{tag}: #{summary}"
  end

  defp maybe_put_filter(filters, _key, nil), do: filters
  defp maybe_put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp preview_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.slice(0, 200)
    |> Redactor.redact()
  end

  defp preview_text(_text), do: ""

  defp error_attrs(reason) do
    %{
      "result_status" => "error",
      "reason_type" => reason_type(reason),
      "summary" => format_reason(reason) |> String.slice(0, 1000)
    }
  end

  defp reason_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_type(reason) when is_binary(reason), do: String.slice(reason, 0, 120)
  defp reason_type({type, _detail}) when is_atom(type), do: Atom.to_string(type)
  defp reason_type(%{__struct__: struct}), do: inspect(struct)
  defp reason_type(_reason), do: "error"

  defp compact_attrs(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp payload_chat_id(%Envelope{} = payload) do
    payload.chat_id
    |> to_string()
  end

  defp maybe_store_follow_up_agent(state, %Envelope{} = payload, %Nex.Agent{} = updated_agent) do
    key =
      runtime_key(
        payload_workspace(payload),
        session_key(payload.channel, payload_chat_id(payload))
      )

    put_in(state.agents[key], %{updated_agent | workspace: payload_workspace(payload)})
  end

  defp maybe_store_follow_up_agent(state, _payload, _updated_agent), do: state

  defp payload_workspace(%Envelope{} = payload) do
    workspace =
      Map.get(payload.metadata || %{}, "workspace") ||
        Map.get(payload.metadata || %{}, :workspace)

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
  defp stream_key(runtime_key, run_id), do: {runtime_key, run_id}
  defp stream_runtime_key({runtime_key, _run_id}), do: runtime_key
  defp stream_run_id({_runtime_key, run_id}), do: run_id

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp streaming_error_message(%Result{} = result) do
    result.final_content || format_reason(result.error)
  end

  defp streaming_error_message(reason), do: format_reason(reason)

  defp publish_task_complete(%Envelope{} = envelope, status) do
    Bus.publish(:task_complete, %{
      channel: envelope.channel,
      chat_id: to_string(envelope.chat_id),
      message_id: envelope.message_id || Map.get(envelope.metadata || %{}, "message_id"),
      origin_channel_id: Map.get(envelope.metadata || %{}, "origin_channel_id"),
      status: status
    })
  end

  defp start_owner_run(workspace, session_key, channel, chat_id) do
    RunControl.start_owner(workspace, session_key, %{
      channel: channel,
      chat_id: chat_id
    })
  end

  defp queued_count(state, key) do
    state.pending_queue
    |> Map.get(key, :queue.new())
    |> :queue.len()
  end

  defp update_queue_count(state, key, count) do
    case Map.get(state.active_tasks, key) do
      %{run_id: run_id} ->
        _ = RunControl.set_queued_count(run_id, count)
        state

      _ ->
        state
    end
  end

  defp task_running?(state, key), do: match?(%{pid: _pid}, Map.get(state.active_tasks, key))
  defp active_task_pid(state, key), do: get_in(state.active_tasks, [key, :pid])

  defp current_owner_run?(state, key, run_id) do
    match?(%{run_id: ^run_id}, Map.get(state.active_tasks, key))
  end

  defp clear_active_task(state, key, run_id) do
    case Map.get(state.active_tasks, key) do
      %{run_id: ^run_id} -> %{state | active_tasks: Map.delete(state.active_tasks, key)}
      _ -> state
    end
  end

  defp find_active_task_by_pid(state, pid) do
    Enum.find(state.active_tasks, fn {_key, entry} -> entry.pid == pid end)
  end

  defp find_follow_up_by_pid(state, pid) do
    Enum.find(state.active_follow_ups, fn {_key, entry} -> entry.pid == pid end)
  end

  defp drop_stream_state(state, key) do
    case Map.get(state.stream_states, key) do
      {:channel_stream, spec, stream_state} ->
        if function_exported?(spec, :cancel_stream, 1), do: spec.cancel_stream(stream_state)

      _ ->
        :ok
    end

    %{state | stream_states: Map.delete(state.stream_states, key)}
  end

  defp cancel_owner_run(state, key, session_key, workspace, run_id, pid, reason) do
    _ = RunControl.cancel_owner(workspace, session_key, reason)

    if Process.whereis(Nex.Agent.Capability.Tool.Registry),
      do: Nex.Agent.Capability.Tool.Registry.cancel_run(run_id)

    if Process.whereis(Nex.Agent.Capability.Subagent),
      do: Nex.Agent.Capability.Subagent.cancel_by_owner_run(run_id)

    state =
      case finalize_stream_session(
             state,
             stream_key(key, run_id),
             {:error, "Cancelled", :cancelled}
           ) do
        {state, _handled?} -> state
      end

    Process.exit(pid, :kill)
    %{state | active_tasks: Map.delete(state.active_tasks, key)}
  end

  defp cancel_follow_up_task(state, key, requester_pid \\ nil) do
    case Map.get(state.active_follow_ups, key) do
      %{pid: pid} when pid == requester_pid ->
        state

      %{pid: pid} = entry ->
        cancel_follow_up_typing_timer(entry)
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        %{state | active_follow_ups: Map.delete(state.active_follow_ups, key)}

      _ ->
        state
    end
  end

  defp clear_follow_up_task(state, key, pid) do
    case Map.get(state.active_follow_ups, key) do
      %{pid: ^pid} -> delete_follow_up_task(state, key)
      _ -> state
    end
  end

  defp delete_follow_up_task(state, key) do
    case Map.get(state.active_follow_ups, key) do
      nil -> state
      entry -> cancel_follow_up_typing_timer(entry)
    end

    %{state | active_follow_ups: Map.delete(state.active_follow_ups, key)}
  end

  defp cancel_follow_up_typing_timer(%{typing_timer_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_follow_up_typing_timer(_entry), do: :ok

  defp run_prompt_task(prompt_fun, agent, prompt, opts) do
    prompt_fun.(agent, prompt, opts)
  rescue
    e ->
      {:error, Exception.message(e)}
  catch
    kind, reason ->
      {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp current_run_id(state, key) do
    case Map.get(state.active_tasks, key) do
      %{run_id: run_id} -> run_id
      _ -> nil
    end
  end

  defp maybe_publish_follow_up_error(payload, reason) do
    unless suppress_outbound?(reason) do
      publish_outbound(payload, "Error: #{format_reason(reason)}", _from_follow_up: true)
    end
  end

  defp cancel_session_subagents(state, session_key, workspace) do
    if Process.whereis(Nex.Agent.Capability.Subagent) do
      _ = Nex.Agent.Capability.Subagent.cancel_by_session(session_key, workspace: workspace)
    end

    state
  end
end
