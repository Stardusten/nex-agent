defmodule Nex.Agent.Channel.Discord do
  @moduledoc """
  Discord channel using Bot Gateway (WebSocket).

  Connects to Discord via the Gateway WebSocket API, receives MESSAGE_CREATE events,
  and sends replies via the REST API. Follows the same Bus pub/sub pattern as Telegram.

  ## Configuration

      %{
        "enabled" => true,
        "token" => "MTIz...",           # Raw bot token (without "Bot " prefix)
        "allow_from" => ["channel_id"], # Allowed channel IDs (empty = all)
        "guild_id" => nil,              # Optional: restrict to a guild
        "show_table_as" => "ascii"      # raw | ascii | embed
      }
  """

  use GenServer
  require Logger

  alias Nex.Agent.{App.Bus, Runtime.Config, Interface.HTTP}
  alias Nex.Agent.Sandbox.Approval
  alias Nex.Agent.Observe.ControlPlane.Log, as: ControlPlaneLog
  alias Nex.Agent.Conversation.Command.{Invocation, Parser}
  alias Nex.Agent.Channel.Discord.WSClient
  alias Nex.Agent.Interface.Inbound.Envelope
  alias Nex.Agent.Interface.IMIR.Renderers.Discord, as: DiscordRenderer
  alias Nex.Agent.Interface.IMIR.Text, as: IMText
  alias Nex.Agent.Interface.Media.Ref
  alias Nex.Agent.Interface.Outbound.Action, as: OutboundAction
  alias Nex.Agent.Interface.Outbound.Approval, as: OutboundApproval

  require ControlPlaneLog

  @discord_api "https://discord.com/api/v10"
  @gateway_url "wss://gateway.discord.gg/?v=10&encoding=json"
  @heartbeat_jitter 0.9
  @reconnect_delay_ms 5_000
  @max_message_length 2000
  @components_v2_flag 32_768
  @table_modes [:raw, :ascii, :embed]
  @eyes_emoji "👀"
  @done_emoji "✅"
  @error_emoji "❌"

  @type thread_meta :: %{
          parent_id: String.t(),
          guild_id: String.t() | nil
        }

  defstruct [
    :instance_id,
    :token,
    :allow_from,
    :guild_id,
    :enabled,
    :show_table_as,
    :http_post_fun,
    :http_patch_fun,
    :http_delete_fun,
    :ws_pid,
    :ws_ref,
    :heartbeat_interval,
    :heartbeat_timer,
    :sequence,
    :session_id,
    :resume_gateway_url,
    :bot_user_id,
    known_threads: %{},
    approval_messages: %{}
  ]

  @type t :: %__MODULE__{
          instance_id: String.t(),
          token: String.t(),
          allow_from: [String.t()],
          guild_id: String.t() | nil,
          enabled: boolean(),
          show_table_as: :raw | :ascii | :embed,
          http_post_fun: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()}),
          http_patch_fun: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()}),
          http_delete_fun: (String.t(), keyword() -> :ok | {:error, term()}),
          ws_pid: pid() | nil,
          ws_ref: reference() | nil,
          heartbeat_interval: integer() | nil,
          heartbeat_timer: reference() | nil,
          sequence: integer() | nil,
          session_id: String.t() | nil,
          resume_gateway_url: String.t() | nil,
          bot_user_id: String.t() | nil,
          known_threads: %{optional(String.t()) => thread_meta()},
          approval_messages: %{optional(String.t()) => map()}
        }

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    instance_id = Keyword.fetch!(opts, :instance_id)
    name = Keyword.get(opts, :name, Nex.Agent.Interface.Channel.Registry.via(instance_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec send_message(String.t(), String.t(), String.t(), map()) :: :ok
  def send_message(instance_id, channel_id, content, metadata \\ %{}) do
    Bus.publish(Nex.Agent.Interface.Outbound.topic_for_channel(instance_id), %{
      chat_id: to_string(channel_id),
      content: content,
      metadata: metadata
    })
  end

  @doc "Send a Discord message synchronously and return the created message_id."
  @spec deliver_message(String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def deliver_message(instance_id, channel_id, content, metadata \\ %{}) do
    case Nex.Agent.Interface.Channel.Registry.whereis(instance_id) do
      nil -> {:error, :discord_not_running}
      pid -> GenServer.call(pid, {:deliver_message, channel_id, content, metadata}, 15_000)
    end
  end

  @doc "Edit an existing Discord message synchronously."
  @spec update_message(String.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def update_message(instance_id, channel_id, message_id, content, metadata \\ %{}) do
    if pid = Nex.Agent.Interface.Channel.Registry.whereis(instance_id) do
      GenServer.call(
        pid,
        {:update_message, channel_id, message_id, content, metadata},
        15_000
      )
    else
      {:error, :discord_not_running}
    end
  end

  @doc "Delete an existing Discord message synchronously."
  @spec delete_message(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_message(instance_id, channel_id, message_id) do
    if pid = Nex.Agent.Interface.Channel.Registry.whereis(instance_id) do
      GenServer.call(pid, {:delete_message, channel_id, message_id}, 15_000)
    else
      {:error, :discord_not_running}
    end
  end

  @doc false
  @spec register_approval_message(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) ::
          :ok
  def register_approval_message(
        instance_id,
        request_id,
        channel_id,
        message_id,
        content,
        metadata
      )
      when is_binary(request_id) and is_binary(message_id) do
    if pid = Nex.Agent.Interface.Channel.Registry.whereis(instance_id) do
      GenServer.cast(
        pid,
        {:register_approval_message, request_id, channel_id, message_id, content, metadata}
      )
    end

    :ok
  end

  @doc "Add a Unicode emoji reaction to a message. Fire-and-forget."
  @spec add_reaction(String.t(), String.t(), String.t(), String.t()) :: :ok
  def add_reaction(instance_id, channel_id, message_id, emoji) do
    if pid = Nex.Agent.Interface.Channel.Registry.whereis(instance_id) do
      GenServer.cast(pid, {:add_reaction, channel_id, message_id, emoji})
    end

    :ok
  end

  @doc "Remove the bot's own reaction from a message. Fire-and-forget."
  @spec remove_reaction(String.t(), String.t(), String.t(), String.t()) :: :ok
  def remove_reaction(instance_id, channel_id, message_id, emoji) do
    if pid = Nex.Agent.Interface.Channel.Registry.whereis(instance_id) do
      GenServer.cast(pid, {:remove_reaction, channel_id, message_id, emoji})
    end

    :ok
  end

  @doc "Trigger the typing indicator in a channel. Fire-and-forget."
  @spec trigger_typing(String.t(), String.t()) :: :ok
  def trigger_typing(instance_id, channel_id) do
    if pid = Nex.Agent.Interface.Channel.Registry.whereis(instance_id) do
      GenServer.cast(pid, {:trigger_typing, channel_id})
    end

    :ok
  end

  # Server

  @impl true
  def init(opts) do
    _ = Application.ensure_all_started(:req)
    _ = Application.ensure_all_started(:mint)

    config = Keyword.get(opts, :config, Config.load())
    instance_id = Keyword.fetch!(opts, :instance_id)

    discord =
      Keyword.get(opts, :channel_config) || Config.channel_instance(config, instance_id) || %{}

    state = %__MODULE__{
      instance_id: instance_id,
      token: normalize_discord_token(Map.get(discord, "token", "")),
      allow_from: normalize_allow_from(Map.get(discord, "allow_from")),
      guild_id: Map.get(discord, "guild_id"),
      enabled: Map.get(discord, "enabled", false) == true,
      show_table_as: normalize_table_mode(Map.get(discord, "show_table_as")),
      http_post_fun: Keyword.get(opts, :http_post_fun, &default_http_post/3),
      http_patch_fun: Keyword.get(opts, :http_patch_fun, &default_http_patch/3),
      http_delete_fun: Keyword.get(opts, :http_delete_fun, &default_http_delete/2),
      sequence: nil,
      session_id: nil,
      approval_messages: %{}
    }

    Bus.subscribe(Nex.Agent.Interface.Outbound.topic_for_channel(instance_id))
    Bus.subscribe(:inbound_ack)
    Bus.subscribe(:task_complete)
    Bus.subscribe(:sandbox_approval_resolved)
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_call({:deliver_message, channel_id, content, metadata}, _from, state) do
    case create_message(channel_id, content, metadata, state) do
      {:ok, message_id} -> {:reply, {:ok, message_id}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:update_message, channel_id, message_id, content, metadata}, _from, state) do
    case edit_message(channel_id, message_id, content, metadata, state) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_message, channel_id, message_id}, _from, state) do
    case delete_channel_message(channel_id, message_id, state) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:add_reaction, channel_id, message_id, emoji}, state) do
    do_add_reaction(channel_id, message_id, emoji, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:remove_reaction, channel_id, message_id, emoji}, state) do
    do_remove_reaction(channel_id, message_id, emoji, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:register_approval_message, request_id, channel_id, message_id, content, metadata},
        state
      ) do
    {:noreply,
     register_approval_message_in_state(
       state,
       request_id,
       channel_id,
       message_id,
       content,
       metadata
     )}
  end

  @impl true
  def handle_cast({:trigger_typing, channel_id}, state) do
    do_trigger_typing(channel_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_continue(:connect, %{enabled: false} = state), do: {:noreply, state}

  @impl true
  def handle_continue(:connect, %{token: ""} = state) do
    Logger.warning("[Discord] No token configured, disabling")
    {:noreply, %{state | enabled: false}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_gateway(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[Discord] Gateway connect failed: #{inspect(reason)}, retrying...")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    send_ws(state.ws_pid, %{op: 1, d: state.sequence})
    timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    {:noreply, %{state | heartbeat_timer: timer}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    state = close_ws(state)
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:discord_ws_connected, pid}, state) do
    ref = Process.monitor(pid)
    Logger.info("[Discord] WS connected pid=#{inspect(pid)}")
    {:noreply, %{state | ws_pid: pid, ws_ref: ref}}
  end

  @impl true
  def handle_info({:discord_ws_message, pid, frame}, %{ws_pid: pid} = state) do
    case Jason.decode(frame) do
      {:ok, payload} ->
        Logger.debug(
          "[Discord] Gateway frame op=#{inspect(payload["op"])} t=#{inspect(payload["t"])} s=#{inspect(payload["s"])}"
        )

        state = handle_gateway_event(payload, state)
        {:noreply, state}

      {:error, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:discord_ws_disconnected, pid, reason}, %{ws_pid: pid} = state) do
    state = cancel_heartbeat(state)
    state = %{state | ws_pid: nil, ws_ref: nil}

    case reason do
      {:remote, 4004, _message} ->
        Logger.error(
          "[Discord] Gateway authentication failed (close code 4004), disabling channel"
        )

        {:noreply, %{state | enabled: false}}

      {:remote, 1000, _message} ->
        Logger.info(
          "[Discord] WebSocket closed normally reason=#{inspect(reason)}, reconnecting..."
        )

        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}

      _ ->
        Logger.warning("[Discord] WebSocket closed reason=#{inspect(reason)}, reconnecting...")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:bus_message, {:channel_outbound, instance_id}, payload}, state)
      when is_map(payload) do
    state =
      if instance_id == state.instance_id do
        do_send(payload, state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:bus_message, :sandbox_approval_resolved, payload}, state)
      when is_map(payload) do
    state =
      if approval_resolution_for_channel?(payload, state.instance_id) do
        update_resolved_approval_message(payload, state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:bus_message, :sandbox_approval_resolved, _payload}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:bus_message, :inbound_ack, %{channel: channel} = payload}, state) do
    if channel == state.instance_id do
      message_id = payload.message_id
      reaction_channel = payload[:origin_channel_id] || payload.chat_id

      if is_binary(message_id) and message_id != "" do
        do_add_reaction(reaction_channel, message_id, @eyes_emoji, state)
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:bus_message, :task_complete, %{channel: channel} = payload}, state) do
    if channel == state.instance_id do
      message_id = payload.message_id
      reaction_channel = payload[:origin_channel_id] || payload.chat_id

      if is_binary(message_id) and message_id != "" do
        do_remove_reaction(reaction_channel, message_id, @eyes_emoji, state)
        final_emoji = if payload.status == :ok, do: @done_emoji, else: @error_emoji
        do_add_reaction(reaction_channel, message_id, final_emoji, state)
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:bus_message, _topic, _payload}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ws_ref: ref} = state) do
    Logger.warning("[Discord] WS process down: #{inspect(reason)}")
    state = cancel_heartbeat(state)
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | ws_pid: nil, ws_ref: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Gateway events

  defp handle_gateway_event(%{"op" => 10, "d" => %{"heartbeat_interval" => interval}}, state) do
    # Hello - start heartbeating and identify
    jittered = trunc(interval * @heartbeat_jitter)
    timer = Process.send_after(self(), :heartbeat, jittered)

    Logger.info(
      "[Discord] HELLO heartbeat_interval=#{interval}ms session_present=#{not is_nil(state.session_id)} seq_present=#{not is_nil(state.sequence)}"
    )

    state = %{state | heartbeat_interval: interval, heartbeat_timer: timer}

    if state.session_id && state.sequence do
      # Resume
      Logger.info("[Discord] Sending RESUME seq=#{state.sequence}")

      send_ws(state.ws_pid, %{
        op: 6,
        d: %{
          token: state.token,
          session_id: state.session_id,
          seq: state.sequence
        }
      })
    else
      # Identify
      Logger.info("[Discord] Sending IDENTIFY")

      send_ws(state.ws_pid, %{
        op: 2,
        d: %{
          token: state.token,
          intents: 33_281,
          properties: %{
            os: "linux",
            browser: "nex_agent",
            device: "nex_agent"
          }
        }
      })
    end

    state
  end

  defp handle_gateway_event(%{"op" => 0, "t" => "READY", "d" => data, "s" => seq}, state) do
    user_id = get_in(data, ["user", "id"])
    session_id = Map.get(data, "session_id")
    resume_url = Map.get(data, "resume_gateway_url")

    Logger.info("[Discord] Connected as #{get_in(data, ["user", "username"])} (#{user_id})")

    %{
      state
      | bot_user_id: user_id,
        session_id: session_id,
        resume_gateway_url: resume_url,
        sequence: seq
    }
  end

  defp handle_gateway_event(%{"op" => 0, "t" => "MESSAGE_CREATE", "d" => data, "s" => seq}, state) do
    state = %{state | sequence: seq}
    handle_message(data, state)
  end

  defp handle_gateway_event(
         %{"op" => 0, "t" => "INTERACTION_CREATE", "d" => data, "s" => seq},
         state
       ) do
    state = %{state | sequence: seq}
    handle_interaction(data, state)
  end

  defp handle_gateway_event(%{"op" => 0, "t" => "GUILD_CREATE", "d" => data, "s" => seq}, state) do
    state = %{state | sequence: seq}
    # Cache active thread IDs from guild payload (same as discord.py's Guild.__init__)
    threads = Map.get(data, "threads", [])

    thread_parents =
      Enum.reduce(threads, %{}, fn thread, acc ->
        case Map.get(thread, "id") do
          thread_id when is_binary(thread_id) and thread_id != "" ->
            Map.put(acc, thread_id, thread_meta(thread))

          _ ->
            acc
        end
      end)

    guild_id = Map.get(data, "id", "?")

    if map_size(thread_parents) > 0 do
      Logger.info(
        "[Discord] GUILD_CREATE guild=#{guild_id} cached #{map_size(thread_parents)} thread(s)"
      )
    end

    %{state | known_threads: Map.merge(state.known_threads, thread_parents)}
  end

  defp handle_gateway_event(%{"op" => 0, "t" => "THREAD_CREATE", "d" => data, "s" => seq}, state) do
    state = %{state | sequence: seq}
    thread_id = Map.get(data, "id")
    meta = thread_meta(data)

    if thread_id do
      Logger.debug(
        "[Discord] THREAD_CREATE thread=#{thread_id} parent=#{meta.parent_id} guild=#{inspect(meta.guild_id)}"
      )

      %{state | known_threads: Map.put(state.known_threads, thread_id, meta)}
    else
      state
    end
  end

  defp handle_gateway_event(%{"op" => 0, "t" => "THREAD_DELETE", "d" => data, "s" => seq}, state) do
    state = %{state | sequence: seq}
    thread_id = Map.get(data, "id")

    if thread_id do
      %{state | known_threads: Map.delete(state.known_threads, thread_id)}
    else
      state
    end
  end

  defp handle_gateway_event(%{"op" => 11}, state) do
    # Heartbeat ACK
    Logger.debug("[Discord] HEARTBEAT_ACK")
    state
  end

  defp handle_gateway_event(%{"op" => 7}, state) do
    # Reconnect requested
    Logger.info("[Discord] Gateway requesting reconnect")
    Process.send_after(self(), :reconnect, 1_000)
    state
  end

  defp handle_gateway_event(%{"op" => 9, "d" => resumable}, state) do
    # Invalid session
    Logger.warning("[Discord] Invalid session (resumable=#{resumable})")
    state = if resumable, do: state, else: %{state | session_id: nil, sequence: nil}
    Process.send_after(self(), :reconnect, Enum.random(1_000..5_000))
    state
  end

  defp handle_gateway_event(%{"s" => seq}, state) when is_integer(seq) do
    %{state | sequence: seq}
  end

  defp handle_gateway_event(_payload, state), do: state

  defp handle_message(data, state) do
    author_id = get_in(data, ["author", "id"])
    channel_id = Map.get(data, "channel_id")
    message_id = Map.get(data, "id")
    content = Map.get(data, "content", "")
    guild_id = Map.get(data, "guild_id")

    if author_id == state.bot_user_id do
      state
    else
      is_dm = is_nil(guild_id)
      thread_meta = Map.get(state.known_threads, channel_id)
      is_thread = is_map(thread_meta)

      mentions_bot =
        data
        |> Map.get("mentions", [])
        |> Enum.any?(fn m -> Map.get(m, "id") == state.bot_user_id end)

      clean_content =
        Regex.replace(~r/<@!?#{state.bot_user_id}>/, content, "")
        |> String.trim()

      parent_chat_id = parent_chat_id(data, thread_meta)

      attachment_refs = discord_attachment_refs(data, state.instance_id)

      cond do
        clean_content == "" and attachment_refs == [] ->
          state

        not allowed?(parent_chat_id, state.allow_from) ->
          state

        is_dm ->
          publish_inbound(channel_id, author_id, clean_content, data, state,
            media_refs: attachment_refs,
            parent_chat_id: parent_chat_id
          )

          state

        is_thread ->
          publish_inbound(channel_id, author_id, clean_content, data, state,
            media_refs: attachment_refs,
            parent_chat_id: parent_chat_id
          )

          state

        mentions_bot ->
          case create_thread_from_message(channel_id, message_id, clean_content, state) do
            {:ok, thread_id} ->
              Logger.info("[Discord] Auto-created thread #{thread_id} for message #{message_id}")

              publish_inbound(thread_id, author_id, clean_content, data, state,
                media_refs: attachment_refs,
                parent_chat_id: channel_id
              )

              # THREAD_CREATE event will also add it, but cache parent immediately for allow_from.
              %{
                state
                | known_threads:
                    Map.put(state.known_threads, thread_id, %{
                      parent_id: to_string(channel_id),
                      guild_id: normalize_optional_string(guild_id)
                    })
              }

            {:error, reason} ->
              Logger.warning(
                "[Discord] Failed to create thread: #{inspect(reason)}, replying in channel"
              )

              publish_inbound(channel_id, author_id, clean_content, data, state,
                media_refs: attachment_refs,
                parent_chat_id: parent_chat_id
              )

              state
          end

        true ->
          state
      end
    end
  end

  defp handle_interaction(data, state) do
    type = Map.get(data, "type")

    cond do
      type == 2 ->
        _ = acknowledge_interaction(data, state)
        publish_interaction_command(data, state)
        state

      type == 3 ->
        _ = acknowledge_component_interaction(data, state)
        state = handle_component_interaction(data, state)
        state

      true ->
        state
    end
  end

  defp publish_interaction_command(data, state) do
    channel_id = Map.get(data, "channel_id")
    author_id = get_in(data, ["member", "user", "id"]) || get_in(data, ["user", "id"])
    guild_id = Map.get(data, "guild_id")
    name = get_in(data, ["data", "name"]) |> to_string()
    options = get_in(data, ["data", "options"]) || []
    args = Enum.flat_map(options, &interaction_option_values/1)
    raw = "/" <> Enum.join([name | args], " ")
    thread_meta = Map.get(state.known_threads, channel_id)
    parent_chat_id = parent_chat_id(data, thread_meta)

    if allowed?(parent_chat_id, state.allow_from) do
      Bus.publish(:inbound, %Envelope{
        channel: state.instance_id,
        chat_id: to_string(channel_id),
        sender_id: to_string(author_id),
        text: raw,
        command: %Invocation{name: name, args: args, raw: raw, source: :native},
        message_type: :text,
        raw: data,
        metadata: %{
          "channel_type" => "discord",
          "guild_id" => guild_id,
          "application_id" => Map.get(data, "application_id"),
          "interaction_id" => Map.get(data, "id"),
          "interaction_token" => Map.get(data, "token"),
          "origin_channel_id" => channel_id,
          "parent_chat_id" => parent_chat_id,
          "username" =>
            get_in(data, ["member", "user", "username"]) || get_in(data, ["user", "username"])
        },
        media_refs: [],
        attachments: []
      })
    end
  end

  defp interaction_option_values(%{"value" => value}) when is_binary(value), do: [value]

  defp interaction_option_values(%{"value" => value}) when is_integer(value),
    do: [Integer.to_string(value)]

  defp interaction_option_values(%{"value" => value}) when is_float(value), do: [to_string(value)]

  defp interaction_option_values(%{"value" => value}) when is_boolean(value),
    do: [to_string(value)]

  defp interaction_option_values(_option), do: []

  defp handle_component_interaction(data, state) do
    custom_id = get_in(data, ["data", "custom_id"])

    case OutboundApproval.custom_id_parts(custom_id) do
      {:ok, %{request_id: request_id, action_id: action_id}} ->
        state = register_interaction_approval_message(data, request_id, state)
        _ = resolve_approval_component(request_id, action_id, data)
        state

      :error ->
        publish_component_command(data, state)
        state
    end
  end

  defp publish_component_command(data, state) do
    custom_id = get_in(data, ["data", "custom_id"])

    with {:ok, raw} <- OutboundApproval.command_for_custom_id(custom_id),
         {:ok, %Invocation{} = invocation} <- Parser.parse(raw) do
      publish_component_invocation(data, %{invocation | source: :native}, state)
    end
  end

  defp register_interaction_approval_message(data, request_id, state) do
    channel_id = Map.get(data, "channel_id")
    message_id = get_in(data, ["message", "id"])
    content = original_component_content(data) || approval_row_content_from_interaction(data)
    metadata = %{"_approval_request_id" => request_id}

    if is_binary(channel_id) and channel_id != "" and
         is_binary(message_id) and message_id != "" do
      register_approval_message_in_state(
        state,
        request_id,
        channel_id,
        message_id,
        content,
        metadata
      )
    else
      state
    end
  end

  defp approval_row_content_from_interaction(data) do
    data
    |> get_in(["message", "content"])
    |> case do
      content when is_binary(content) and content != "" -> content
      _ -> "Approval request"
    end
  end

  defp resolve_approval_component(request_id, action_id, data) do
    actor = approval_actor_from_interaction(data)

    case OutboundApproval.choice_for_action(action_id) do
      {:approve, choice} ->
        if Process.whereis(Approval) do
          Approval.approve_request(request_id, choice, authorized_actor: actor)
        else
          {:error, :approval_unavailable}
        end

      {:deny, choice} ->
        if Process.whereis(Approval) do
          Approval.deny_request(request_id, choice, authorized_actor: actor)
        else
          {:error, :approval_unavailable}
        end

      :error ->
        {:error, :unknown_approval_action}
    end
  end

  defp approval_actor_from_interaction(data) do
    %{
      "sender_id" => get_in(data, ["member", "user", "id"]) || get_in(data, ["user", "id"]),
      "username" =>
        get_in(data, ["member", "user", "username"]) || get_in(data, ["user", "username"]),
      "channel" => Map.get(data, "channel_id")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp publish_component_invocation(data, %Invocation{} = invocation, state) do
    channel_id = Map.get(data, "channel_id")
    author_id = get_in(data, ["member", "user", "id"]) || get_in(data, ["user", "id"])
    guild_id = Map.get(data, "guild_id")
    thread_meta = Map.get(state.known_threads, channel_id)
    parent_chat_id = parent_chat_id(data, thread_meta)

    if allowed?(parent_chat_id, state.allow_from) do
      Bus.publish(:inbound, %Envelope{
        channel: state.instance_id,
        chat_id: to_string(channel_id),
        sender_id: to_string(author_id),
        text: invocation.raw,
        command: invocation,
        message_type: :text,
        raw: data,
        metadata: %{
          "channel_type" => "discord",
          "guild_id" => guild_id,
          "application_id" => Map.get(data, "application_id"),
          "interaction_id" => Map.get(data, "id"),
          "interaction_token" => Map.get(data, "token"),
          "origin_channel_id" => channel_id,
          "parent_chat_id" => parent_chat_id,
          "component_custom_id" => get_in(data, ["data", "custom_id"]),
          "username" =>
            get_in(data, ["member", "user", "username"]) || get_in(data, ["user", "username"])
        },
        media_refs: [],
        attachments: []
      })
    end
  end

  defp acknowledge_interaction(data, state) do
    interaction_id = Map.get(data, "id")
    token = Map.get(data, "token")

    if is_binary(interaction_id) and interaction_id != "" and is_binary(token) and token != "" do
      state.http_post_fun.(
        "#{@discord_api}/interactions/#{interaction_id}/#{token}/callback",
        %{"type" => 5},
        request_headers(%{}, state)
      )
    else
      {:error, :invalid_interaction}
    end
  end

  defp acknowledge_component_interaction(data, state) do
    interaction_id = Map.get(data, "id")
    token = Map.get(data, "token")
    custom_id = get_in(data, ["data", "custom_id"])

    if is_binary(interaction_id) and interaction_id != "" and is_binary(token) and token != "" do
      state.http_post_fun.(
        "#{@discord_api}/interactions/#{interaction_id}/#{token}/callback",
        component_ack_body(custom_id, data),
        request_headers(%{}, state)
      )
    else
      {:error, :invalid_interaction}
    end
  end

  defp component_ack_body(custom_id, data) do
    _ = data
    _ = custom_id
    %{"type" => 6}
  end

  defp original_component_content(data) when is_map(data) do
    data
    |> get_in(["message", "components"])
    |> List.wrap()
    |> Enum.find_value(&component_text_content/1)
  end

  defp original_component_content(_data), do: nil

  defp component_text_content(%{"type" => 10, "content" => content}) when is_binary(content) do
    content
  end

  defp component_text_content(%{"components" => children}) when is_list(children) do
    Enum.find_value(children, &component_text_content/1)
  end

  defp component_text_content(_component), do: nil

  defp publish_inbound(chat_id, author_id, content, data, state, opts) do
    origin_channel_id = Map.get(data, "channel_id")
    parent_chat_id = Keyword.get(opts, :parent_chat_id)
    media_refs = Keyword.get(opts, :media_refs, [])

    metadata =
      %{
        "channel_type" => "discord",
        "guild_id" => Map.get(data, "guild_id"),
        "message_id" => Map.get(data, "id"),
        "origin_channel_id" => origin_channel_id,
        "username" => get_in(data, ["author", "username"])
      }
      |> maybe_put_metadata("parent_chat_id", parent_chat_id)

    Bus.publish(:inbound, %Envelope{
      channel: state.instance_id,
      chat_id: to_string(chat_id),
      sender_id: to_string(author_id),
      text: content,
      message_type: :text,
      raw: data,
      metadata: metadata,
      media_refs: media_refs,
      attachments: []
    })
  end

  defp discord_attachment_refs(data, instance_id) do
    data
    |> Map.get("attachments", [])
    |> Enum.flat_map(fn
      attachment when is_map(attachment) ->
        url = Map.get(attachment, "url")

        if is_binary(url) and url != "" do
          mime_type = Map.get(attachment, "content_type")
          filename = Map.get(attachment, "filename")

          [
            %Ref{
              channel: instance_id,
              kind: discord_attachment_kind(mime_type, filename),
              message_id: Map.get(data, "id"),
              mime_type: mime_type,
              filename: filename,
              platform_ref: %{
                "id" => Map.get(attachment, "id"),
                "url" => url,
                "proxy_url" => Map.get(attachment, "proxy_url")
              },
              metadata: %{
                "size" => Map.get(attachment, "size"),
                "width" => Map.get(attachment, "width"),
                "height" => Map.get(attachment, "height")
              }
            }
          ]
        else
          []
        end

      _other ->
        []
    end)
  end

  defp discord_attachment_kind(mime_type, filename) do
    cond do
      is_binary(mime_type) and String.starts_with?(mime_type, "image/") -> :image
      is_binary(mime_type) and String.starts_with?(mime_type, "audio/") -> :audio
      is_binary(mime_type) and String.starts_with?(mime_type, "video/") -> :video
      image_extension?(filename) -> :image
      audio_extension?(filename) -> :audio
      video_extension?(filename) -> :video
      true -> :file
    end
  end

  defp image_extension?(filename), do: extension_in?(filename, ~w(.png .jpg .jpeg .gif .webp))
  defp audio_extension?(filename), do: extension_in?(filename, ~w(.mp3 .wav .m4a .ogg .flac))
  defp video_extension?(filename), do: extension_in?(filename, ~w(.mp4 .mov .webm .mkv))

  defp extension_in?(filename, extensions) when is_binary(filename) do
    filename |> Path.extname() |> String.downcase() |> Kernel.in(extensions)
  end

  defp extension_in?(_filename, _extensions), do: false

  defp create_thread_from_message(channel_id, message_id, content, state) do
    thread_name =
      content
      |> String.slice(0, 80)
      |> case do
        "" -> "Nex"
        name -> if String.length(content) > 80, do: String.slice(name, 0, 77) <> "...", else: name
      end

    case state.http_post_fun.(
           "#{@discord_api}/channels/#{channel_id}/messages/#{message_id}/threads",
           %{
             "name" => thread_name,
             "auto_archive_duration" => 1440
           },
           request_headers(%{}, state)
         ) do
      {:ok, response} ->
        case Map.get(response, "id") do
          id when is_binary(id) and id != "" -> {:ok, id}
          _ -> {:error, {:missing_thread_id, response}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # REST API

  defp do_send(%{chat_id: channel_id, content: content, metadata: metadata}, state)
       when is_map(metadata) do
    channel_id = to_string(channel_id || "")

    case interaction_response_token(metadata) do
      token when is_binary(token) ->
        application_id = interaction_application_id(metadata) || state.bot_user_id

        content
        |> normalize_outbound_text()
        |> Enum.join("\n\n")
        |> render_discord_body(metadata, state)
        |> edit_interaction_response(application_id, token, state)
        |> case do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("[Discord] Interaction response failed: #{inspect(reason)}")
        end

        state

      _ ->
        send_channel_message(channel_id, content, metadata, state)
    end
  end

  defp do_send(%{chat_id: channel_id, content: content}, state) do
    send_channel_message(to_string(channel_id || ""), content, %{}, state)
  end

  defp do_send(payload, state) do
    Logger.error("[Discord] Invalid outbound payload: #{inspect(payload)}")
    state
  end

  defp send_channel_message(channel_id, content, metadata, state) do
    content
    |> normalize_outbound_text()
    |> Enum.reduce(state, fn segment, acc_state ->
      render_discord_bodies(segment, metadata, acc_state)
      |> Enum.reduce(acc_state, fn body, inner_state ->
        case create_message(channel_id, body, metadata, inner_state) do
          {:ok, message_id} ->
            maybe_register_outbound_approval_message(
              inner_state,
              channel_id,
              message_id,
              segment,
              metadata
            )

          {:error, reason} ->
            Logger.error("[Discord] Send failed: #{inspect(reason)}")
            inner_state
        end
      end)
    end)
  end

  defp create_message(channel_id, content, metadata, state) do
    body = render_discord_body(content, metadata, state)
    observe_discord_outbound_body(channel_id, body, state)

    with :ok <- validate_outbound_message(channel_id, body, state),
         {:ok, response} <-
           state.http_post_fun.(
             "#{@discord_api}/channels/#{channel_id}/messages",
             body,
             request_headers(metadata, state)
           ) do
      observe_discord_message_response(channel_id, response, state)

      case Map.get(response, "id") || Map.get(response, :id) do
        id when is_binary(id) and id != "" -> {:ok, id}
        _ -> {:error, {:missing_message_id, response}}
      end
    end
  end

  defp edit_message(channel_id, message_id, content, metadata, state) do
    body = render_discord_body(content, metadata, state)

    with :ok <- validate_outbound_message(channel_id, body, state),
         true <- (is_binary(message_id) and message_id != "") or {:error, :invalid_message_id},
         {:ok, _response} <-
           state.http_patch_fun.(
             "#{@discord_api}/channels/#{channel_id}/messages/#{message_id}",
             body,
             request_headers(metadata, state)
           ) do
      :ok
    end
  end

  defp delete_channel_message(channel_id, message_id, state) do
    with true <- (is_binary(channel_id) and channel_id != "") or {:error, :invalid_channel_id},
         true <- (is_binary(message_id) and message_id != "") or {:error, :invalid_message_id},
         true <- state.token not in [nil, ""] or {:error, :missing_token} do
      state.http_delete_fun.(
        "#{@discord_api}/channels/#{channel_id}/messages/#{message_id}",
        request_headers(%{}, state)
      )
    end
  end

  defp render_discord_bodies(content, metadata, state)
       when is_binary(content) and is_map(metadata) do
    case render_discord_action_body(content, metadata) do
      nil ->
        content
        |> DiscordRenderer.render_payload(show_table_as: state.show_table_as)
        |> discord_payload_to_bodies()

      body ->
        [body]
    end
  end

  defp render_discord_bodies(content, _metadata, state) when is_binary(content) do
    content
    |> DiscordRenderer.render_payload(show_table_as: state.show_table_as)
    |> discord_payload_to_bodies()
  end

  defp render_discord_bodies(content, metadata, state),
    do: [render_discord_body(content, metadata, state)]

  defp render_discord_body(%{} = body, _metadata, _state) do
    content = Map.get(body, "content", Map.get(body, :content, ""))
    embeds = Map.get(body, "embeds", Map.get(body, :embeds, []))
    components = Map.get(body, "components", Map.get(body, :components))
    flags = Map.get(body, "flags", Map.get(body, :flags))

    if is_list(components) and components != [] do
      %{}
      |> maybe_put_non_empty("content", content)
      |> maybe_put_list("embeds", embeds)
      |> Map.put("components", components)
      |> maybe_put_integer("flags", flags)
    else
      %{
        "content" => to_string(content || ""),
        "embeds" => if(is_list(embeds), do: embeds, else: [])
      }
    end
  end

  defp render_discord_body(content, metadata, state) when is_binary(content) do
    case render_discord_action_body(content, metadata) do
      nil ->
        content
        |> DiscordRenderer.render_payload(show_table_as: state.show_table_as)
        |> discord_payload_to_body()

      body ->
        body
    end
  end

  defp render_discord_body(content, _metadata, _state),
    do: %{"content" => to_string(content || ""), "embeds" => []}

  defp render_discord_action_body(content, metadata) when is_map(metadata) do
    render_discord_approval_body(content, metadata) ||
      render_discord_generic_action_body(metadata)
  end

  defp render_discord_action_body(_content, _metadata), do: nil

  defp render_discord_approval_body(_content, metadata) when is_map(metadata) do
    case OutboundApproval.request(metadata) do
      %{} = request ->
        request_id = Map.get(request, "request_id")
        actions = Map.get(request, "actions", [])

        buttons =
          actions
          |> Enum.filter(&is_map/1)
          |> Enum.map(&discord_approval_button(request_id, &1))
          |> Enum.reject(&is_nil/1)

        if is_binary(request_id) and buttons != [] do
          %{
            "flags" => @components_v2_flag,
            "components" =>
              [
                %{"type" => 10, "content" => approval_row_content(request, :pending)}
              ] ++
                approval_risk_components(request) ++
                [
                  %{"type" => 1, "components" => buttons}
                ]
          }
        end

      _ ->
        nil
    end
  end

  defp render_discord_approval_body(_content, _metadata), do: nil

  defp render_discord_generic_action_body(metadata) when is_map(metadata) do
    case OutboundAction.action(metadata) do
      %{} = action ->
        content = OutboundAction.render_fallback(action)

        if content != "" do
          %{
            "flags" => @components_v2_flag,
            "components" => [%{"type" => 10, "content" => content}]
          }
        end

      _ ->
        nil
    end
  end

  defp render_discord_generic_action_body(_metadata), do: nil

  defp discord_approval_button(request_id, %{} = action) do
    action_id = Map.get(action, "id")
    label = Map.get(action, "label")

    if is_binary(request_id) and is_binary(action_id) and is_binary(label) do
      %{
        "type" => 2,
        "style" => discord_button_style(Map.get(action, "style")),
        "label" => label,
        "custom_id" => OutboundApproval.custom_id(request_id, action_id)
      }
    end
  end

  defp discord_button_style("primary"), do: 1
  defp discord_button_style("secondary"), do: 2
  defp discord_button_style("success"), do: 3
  defp discord_button_style("danger"), do: 4
  defp discord_button_style(_style), do: 2

  defp maybe_register_outbound_approval_message(state, channel_id, message_id, _content, metadata) do
    case OutboundApproval.request(metadata) do
      %{"request_id" => request_id} = request when is_binary(request_id) ->
        register_approval_message_in_state(
          state,
          request_id,
          channel_id,
          message_id,
          approval_row_content(request, :pending),
          metadata
        )

      _ ->
        state
    end
  end

  defp register_approval_message_in_state(
         state,
         request_id,
         channel_id,
         message_id,
         content,
         metadata
       ) do
    record = %{
      channel_id: to_string(channel_id || ""),
      message_id: to_string(message_id || ""),
      content: to_string(content || ""),
      metadata: metadata || %{}
    }

    %{state | approval_messages: Map.put(state.approval_messages, request_id, record)}
  end

  defp approval_resolution_for_channel?(payload, instance_id) do
    channel = Map.get(payload, :channel) || Map.get(payload, "channel")
    is_nil(channel) or channel == instance_id
  end

  defp update_resolved_approval_message(payload, state) do
    request_id = Map.get(payload, :request_id) || Map.get(payload, "request_id")

    case Map.get(state.approval_messages, request_id) do
      nil ->
        state

      record ->
        status =
          normalize_approval_status(Map.get(payload, :status) || Map.get(payload, "status"))

        choice =
          normalize_approval_choice(Map.get(payload, :choice) || Map.get(payload, "choice"))

        request = Map.get(payload, :request) || Map.get(payload, "request")
        content = approval_row_content(request || record.metadata, status, choice, record.content)

        body = %{
          "flags" => @components_v2_flag,
          "components" => [%{"type" => 10, "content" => content}]
        }

        case state.http_patch_fun.(
               "#{@discord_api}/channels/#{record.channel_id}/messages/#{record.message_id}",
               body,
               request_headers(%{}, state)
             ) do
          {:ok, _response} ->
            %{state | approval_messages: Map.delete(state.approval_messages, request_id)}

          {:error, reason} ->
            Logger.warning("[Discord] Approval message update failed: #{inspect(reason)}")
            state
        end
    end
  end

  defp approval_row_content(request, :pending) do
    approval_row_base(request) <> " _(Waiting approval)_"
  end

  defp approval_risk_components(request) do
    case approval_risk_hint(request) do
      nil -> []
      hint -> [%{"type" => 10, "content" => "_Risk: #{hint}_"}]
    end
  end

  defp approval_risk_hint(%Nex.Agent.Sandbox.Approval.Request{metadata: metadata}) do
    approval_risk_hint(metadata)
  end

  defp approval_risk_hint(%{} = request) do
    request = OutboundApproval.request(request) || stringify_map_keys(request)

    hint =
      Map.get(request, "risk_hint") ||
        get_in(request, ["request_metadata", "risk_hint"]) ||
        get_in(request, ["metadata", "risk_hint"])

    case hint do
      value when is_binary(value) and value != "" -> approval_subject(value)
      _ -> nil
    end
  end

  defp approval_risk_hint(_request), do: nil

  defp approval_row_content(request, status, choice, fallback) do
    base =
      case approval_row_base(request) do
        "" -> strip_approval_status(fallback)
        value -> value
      end

    "#{base} _(#{OutboundApproval.status_label(status, choice)})_"
  end

  defp approval_row_base(%Nex.Agent.Sandbox.Approval.Request{kind: :command, subject: subject}) do
    "⚙️ Bash - " <> approval_subject(subject)
  end

  defp approval_row_base(%Nex.Agent.Sandbox.Approval.Request{description: description}) do
    "🔐 Approval - " <> approval_subject(description)
  end

  defp approval_row_base(%{} = request) do
    request = OutboundApproval.request(request) || stringify_map_keys(request)
    kind = Map.get(request, "kind")
    subject = Map.get(request, "subject")
    description = Map.get(request, "description")

    cond do
      kind == "command" and is_binary(subject) and subject != "" ->
        "⚙️ Bash - " <> approval_subject(subject)

      is_binary(description) and description != "" ->
        "🔐 Approval - " <> approval_subject(description)

      true ->
        ""
    end
  end

  defp approval_row_base(_request), do: ""

  defp approval_subject(subject) do
    subject
    |> to_string()
    |> String.replace("\n", " ")
    |> String.trim()
    |> String.slice(0, 140)
  end

  defp strip_approval_status(content) do
    content
    |> to_string()
    |> String.replace(~r/\s+_\([^)]*\)_\s*$/, "")
    |> String.trim()
  end

  defp normalize_approval_status(status)
       when status in [:approved, :denied, :timeout, :cancelled],
       do: status

  defp normalize_approval_status(status) when is_binary(status) do
    case status do
      "approved" -> :approved
      "denied" -> :denied
      "timeout" -> :timeout
      "cancelled" -> :cancelled
      _ -> :approved
    end
  end

  defp normalize_approval_status(_status), do: :approved

  defp normalize_approval_choice(choice)
       when choice in [:once, :all, :session, :similar, :always, :grant],
       do: choice

  defp normalize_approval_choice(choice) when is_binary(choice) do
    case choice do
      "once" -> :once
      "all" -> :all
      "session" -> :session
      "similar" -> :similar
      "always" -> :always
      "grant" -> :grant
      _ -> :once
    end
  end

  defp normalize_approval_choice(_choice), do: :once

  defp stringify_map_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp maybe_put_non_empty(map, key, value) when is_binary(value) do
    if String.trim(value) == "", do: map, else: Map.put(map, key, value)
  end

  defp maybe_put_non_empty(map, _key, _value), do: map

  defp maybe_put_list(map, key, value) when is_list(value) and value != [],
    do: Map.put(map, key, value)

  defp maybe_put_list(map, _key, _value), do: map

  defp maybe_put_integer(map, key, value) when is_integer(value), do: Map.put(map, key, value)
  defp maybe_put_integer(map, _key, _value), do: map

  defp discord_payload_to_bodies(%{content: content, embeds: embeds}) do
    content_chunks = IMText.chunk_message(content || "", @max_message_length)
    embed_batches = Enum.chunk_every(embeds || [], 10)

    cond do
      embed_batches == [] ->
        Enum.map(content_chunks, &%{"content" => &1, "embeds" => []})

      length(content_chunks) <= 1 and length(embed_batches) == 1 ->
        [%{"content" => List.first(content_chunks) || "", "embeds" => List.first(embed_batches)}]

      true ->
        Enum.map(content_chunks, &%{"content" => &1, "embeds" => []}) ++
          Enum.map(embed_batches, &%{"content" => "", "embeds" => &1})
    end
  end

  defp discord_payload_to_body(%{content: content, embeds: embeds}) do
    content = content || ""
    embeds = embeds || []

    if String.length(content) <= @max_message_length do
      %{"content" => content, "embeds" => embeds}
    else
      content
      |> IMText.chunk_message(@max_message_length)
      |> List.first()
      |> then(&%{"content" => &1 || "", "embeds" => embeds})
    end
  end

  defp validate_outbound_message(channel_id, body, state) do
    cond do
      not is_binary(channel_id) or channel_id == "" ->
        {:error, :invalid_channel_id}

      not valid_discord_body?(body) ->
        {:error, :invalid_content}

      state.token in [nil, ""] ->
        {:error, :missing_token}

      true ->
        :ok
    end
  end

  defp valid_discord_body?(%{"content" => content, "embeds" => embeds}) do
    (is_binary(content) and String.trim(content) != "") or
      (is_list(embeds) and embeds != [])
  end

  defp valid_discord_body?(%{"components" => components}) when is_list(components) do
    components != []
  end

  defp valid_discord_body?(_body), do: false

  defp observe_discord_outbound_body(
         channel_id,
         %{"content" => content, "embeds" => embeds},
         state
       ) do
    embeds = if is_list(embeds), do: embeds, else: []
    content = to_string(content || "")
    field_count = Enum.reduce(embeds, 0, &(&2 + embed_field_count(&1)))

    ControlPlaneLog.info(
      "discord.outbound.rendered",
      %{
        "content_chars" => String.length(content),
        "content_empty" => String.trim(content) == "",
        "embed_count" => length(embeds),
        "embed_field_count" => field_count,
        "embed_only" => String.trim(content) == "" and embeds != [],
        "table_mode" => Atom.to_string(state.show_table_as)
      },
      context: %{"channel" => state.instance_id, "chat_id" => channel_id}
    )
  rescue
    _e -> :ok
  end

  defp observe_discord_outbound_body(_channel_id, _body, _state), do: :ok

  defp embed_field_count(%{"fields" => fields}) when is_list(fields), do: length(fields)
  defp embed_field_count(_embed), do: 0

  defp observe_discord_message_response(channel_id, response, state) when is_map(response) do
    embeds = response_embeds(response)
    flags = Map.get(response, "flags") || Map.get(response, :flags)

    ControlPlaneLog.info(
      "discord.outbound.response",
      %{
        "message_id_present" => present?(Map.get(response, "id") || Map.get(response, :id)),
        "response_embed_count" => length(embeds),
        "response_embed_field_count" => Enum.reduce(embeds, 0, &(&2 + embed_field_count(&1))),
        "response_flags" => flags,
        "response_suppress_embeds" => suppress_embeds?(flags)
      },
      context: %{"channel" => state.instance_id, "chat_id" => channel_id}
    )
  rescue
    _e -> :ok
  end

  defp observe_discord_message_response(_channel_id, _response, _state), do: :ok

  defp response_embeds(response) do
    case Map.get(response, "embeds") || Map.get(response, :embeds) do
      embeds when is_list(embeds) -> embeds
      _ -> []
    end
  end

  defp suppress_embeds?(flags) when is_integer(flags), do: Bitwise.band(flags, 4) == 4
  defp suppress_embeds?(_flags), do: false

  defp present?(value), do: is_binary(value) and value != ""

  defp normalize_outbound_text(content) when is_binary(content) do
    content
    |> IMText.split_messages()
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_outbound_text(_content), do: []

  defp normalize_table_mode(mode) when is_atom(mode) and mode in @table_modes, do: mode

  defp normalize_table_mode(mode) when is_binary(mode) do
    mode
    |> String.trim()
    |> String.downcase()
    |> case do
      "raw" -> :raw
      "ascii" -> :ascii
      "embed" -> :embed
      _ -> :ascii
    end
  end

  defp normalize_table_mode(_mode), do: :ascii

  defp request_headers(_metadata, state) do
    [{"authorization", discord_authorization(state.token)}]
  end

  defp interaction_response_token(metadata) when is_map(metadata) do
    Map.get(metadata, "interaction_token") || Map.get(metadata, :interaction_token)
  end

  defp interaction_application_id(metadata) when is_map(metadata) do
    Map.get(metadata, "application_id") || Map.get(metadata, :application_id)
  end

  defp edit_interaction_response(body, application_id, token, state)
       when is_binary(application_id) and application_id != "" do
    state.http_patch_fun.(
      "#{@discord_api}/webhooks/#{application_id}/#{token}/messages/@original",
      body,
      request_headers(%{}, state)
    )
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp edit_interaction_response(_content, _application_id, _token, _state),
    do: {:error, :missing_application_id}

  # Reaction & typing helpers

  defp do_add_reaction(channel_id, message_id, emoji, state) do
    Task.start(fn ->
      encoded_emoji = URI.encode(emoji)

      url =
        "#{@discord_api}/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded_emoji}/@me"

      case default_http_put(url, [{"authorization", discord_authorization(state.token)}]) do
        :ok ->
          Logger.debug("[Discord] Added #{emoji} reaction to #{message_id}")

        {:error, reason} ->
          Logger.warning("[Discord] Failed to add reaction: #{inspect(reason)}")
      end
    end)
  end

  defp do_remove_reaction(channel_id, message_id, emoji, state) do
    Task.start(fn ->
      encoded_emoji = URI.encode(emoji)

      url =
        "#{@discord_api}/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded_emoji}/@me"

      case state.http_delete_fun.(url, [{"authorization", discord_authorization(state.token)}]) do
        :ok ->
          Logger.debug("[Discord] Removed #{emoji} reaction from #{message_id}")

        {:error, reason} ->
          Logger.warning("[Discord] Failed to remove reaction: #{inspect(reason)}")
      end
    end)
  end

  defp do_trigger_typing(channel_id, state) do
    Task.start(fn ->
      url = "#{@discord_api}/channels/#{channel_id}/typing"

      case state.http_post_fun.(url, %{}, [{"authorization", discord_authorization(state.token)}]) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("[Discord] Typing trigger failed: #{inspect(reason)}")
      end
    end)
  end

  defp default_http_put(url, headers) do
    req_opts =
      [headers: headers, retry: false, receive_timeout: 15_000]
      |> HTTP.maybe_add_proxy(url)

    case HTTP.put(url, req_opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 429, body: body}} ->
        retry_after = get_in(body, ["retry_after"]) || get_in(body, [:retry_after]) || 1
        Logger.warning("[Discord] Rate limited, retry after #{retry_after}s")
        Process.sleep(trunc(retry_after * 1000))
        default_http_put(url, headers)

      {:ok, %{status: status, body: response}} ->
        {:error, {:http_error, status, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_http_delete(url, headers) do
    req_opts =
      [headers: headers, retry: false, receive_timeout: 15_000]
      |> HTTP.maybe_add_proxy(url)

    case HTTP.delete(url, req_opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 429, body: body}} ->
        retry_after = get_in(body, ["retry_after"]) || get_in(body, [:retry_after]) || 1
        Logger.warning("[Discord] Rate limited, retry after #{retry_after}s")
        Process.sleep(trunc(retry_after * 1000))
        default_http_delete(url, headers)

      {:ok, %{status: status, body: response}} ->
        {:error, {:http_error, status, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # WebSocket helpers

  defp connect_gateway(state) do
    url =
      case state.resume_gateway_url do
        url when is_binary(url) and url != "" -> "#{url}?v=10&encoding=json"
        _ -> @gateway_url
      end

    Logger.info(
      "[Discord] Connecting gateway url=#{url} session_present=#{not is_nil(state.session_id)} seq_present=#{not is_nil(state.sequence)}"
    )

    case WSClient.start_link(url, [], self()) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Logger.info("[Discord] Gateway transport started pid=#{inspect(pid)}")
        {:ok, %{state | ws_pid: pid, ws_ref: ref}}

      {:error, reason} ->
        Logger.warning("[Discord] Gateway transport start failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_ws(nil, _payload), do: :ok

  defp send_ws(ws_pid, payload) do
    WSClient.send_json(ws_pid, payload)
  rescue
    _ -> :ok
  end

  defp close_ws(%{ws_pid: nil} = state), do: state

  defp close_ws(%{ws_pid: pid} = state) do
    _ = Process.exit(pid, :shutdown)
    cancel_heartbeat(%{state | ws_pid: nil, ws_ref: nil})
  rescue
    _ -> cancel_heartbeat(%{state | ws_pid: nil, ws_ref: nil})
  end

  defp cancel_heartbeat(%{heartbeat_timer: nil} = state), do: state

  defp cancel_heartbeat(%{heartbeat_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | heartbeat_timer: nil}
  end

  defp allowed?(_channel_id, []), do: true

  defp allowed?(channel_id, allow_from) do
    to_string(channel_id) in allow_from
  end

  defp normalize_discord_token(token) when is_binary(token) do
    token
    |> String.trim()
    |> String.replace_prefix("Bot ", "")
    |> String.replace_prefix("bot ", "")
  end

  defp normalize_discord_token(_token), do: ""

  defp normalize_allow_from(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_allow_from(_list), do: []

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, _key, ""), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, to_string(value))

  defp parent_chat_id(data, thread_meta) do
    thread_parent_id(thread_meta) || Map.get(data, "parent_id") || Map.get(data, "channel_id")
  end

  defp thread_meta(data) when is_map(data) do
    %{
      parent_id: to_string(Map.get(data, "parent_id") || Map.get(data, "id") || ""),
      guild_id: normalize_optional_string(Map.get(data, "guild_id"))
    }
  end

  defp thread_parent_id(%{parent_id: parent_id}) when is_binary(parent_id) and parent_id != "",
    do: parent_id

  defp thread_parent_id(_meta), do: nil

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp default_http_post(url, body, headers) do
    req_opts =
      [json: body, headers: headers, retry: false, receive_timeout: 15_000]
      |> HTTP.maybe_add_proxy(url)

    case HTTP.post(url, req_opts) do
      {:ok, %{status: status, body: response}} when status in 200..299 and is_map(response) ->
        {:ok, response}

      {:ok, %{status: 429, body: response_body}} ->
        retry_after =
          get_in(response_body, ["retry_after"]) || get_in(response_body, [:retry_after]) || 1

        Logger.warning("[Discord] Rate limited, retry after #{retry_after}s")
        Process.sleep(trunc(retry_after * 1000))
        default_http_post(url, body, headers)

      {:ok, %{status: status, body: response}} ->
        {:error, {:http_error, status, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_http_patch(url, body, headers) do
    req_opts =
      [json: body, headers: headers, retry: false, receive_timeout: 15_000]
      |> HTTP.maybe_add_proxy(url)

    case HTTP.patch(url, req_opts) do
      {:ok, %{status: status, body: response}} when status in 200..299 and is_map(response) ->
        {:ok, response}

      {:ok, %{status: 429, body: response_body}} ->
        retry_after =
          get_in(response_body, ["retry_after"]) || get_in(response_body, [:retry_after]) || 1

        Logger.warning("[Discord] Rate limited, retry after #{retry_after}s")
        Process.sleep(trunc(retry_after * 1000))
        default_http_patch(url, body, headers)

      {:ok, %{status: status, body: response}} ->
        {:error, {:http_error, status, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discord_authorization("Bot " <> token), do: "Bot #{token}"
  defp discord_authorization(token), do: "Bot #{token}"
end
