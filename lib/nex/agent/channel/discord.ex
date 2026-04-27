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

  alias Nex.Agent.{Bus, Config, HTTP}
  alias Nex.Agent.ControlPlane.Log, as: ControlPlaneLog
  alias Nex.Agent.Command.Invocation
  alias Nex.Agent.Channel.Discord.WSClient
  alias Nex.Agent.Inbound.Envelope
  alias Nex.Agent.IMIR.Renderers.Discord, as: DiscordRenderer
  alias Nex.Agent.IMIR.Text, as: IMText

  require ControlPlaneLog

  @discord_api "https://discord.com/api/v10"
  @gateway_url "wss://gateway.discord.gg/?v=10&encoding=json"
  @heartbeat_jitter 0.9
  @reconnect_delay_ms 5_000
  @max_message_length 2000
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
    :ws_pid,
    :ws_ref,
    :heartbeat_interval,
    :heartbeat_timer,
    :sequence,
    :session_id,
    :resume_gateway_url,
    :bot_user_id,
    known_threads: %{}
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
          ws_pid: pid() | nil,
          ws_ref: reference() | nil,
          heartbeat_interval: integer() | nil,
          heartbeat_timer: reference() | nil,
          sequence: integer() | nil,
          session_id: String.t() | nil,
          resume_gateway_url: String.t() | nil,
          bot_user_id: String.t() | nil,
          known_threads: %{optional(String.t()) => thread_meta()}
        }

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    instance_id = Keyword.fetch!(opts, :instance_id)
    name = Keyword.get(opts, :name, Nex.Agent.Channel.Registry.via(instance_id))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec send_message(String.t(), String.t(), String.t(), map()) :: :ok
  def send_message(instance_id, channel_id, content, metadata \\ %{}) do
    Bus.publish(Nex.Agent.Outbound.topic_for_channel(instance_id), %{
      chat_id: to_string(channel_id),
      content: content,
      metadata: metadata
    })
  end

  @doc "Send a Discord message synchronously and return the created message_id."
  @spec deliver_message(String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def deliver_message(instance_id, channel_id, content, metadata \\ %{}) do
    case Nex.Agent.Channel.Registry.whereis(instance_id) do
      nil -> {:error, :discord_not_running}
      pid -> GenServer.call(pid, {:deliver_message, channel_id, content, metadata}, 15_000)
    end
  end

  @doc "Edit an existing Discord message synchronously."
  @spec update_message(String.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def update_message(instance_id, channel_id, message_id, content, metadata \\ %{}) do
    if pid = Nex.Agent.Channel.Registry.whereis(instance_id) do
      GenServer.call(
        pid,
        {:update_message, channel_id, message_id, content, metadata},
        15_000
      )
    else
      {:error, :discord_not_running}
    end
  end

  @doc "Add a Unicode emoji reaction to a message. Fire-and-forget."
  @spec add_reaction(String.t(), String.t(), String.t(), String.t()) :: :ok
  def add_reaction(instance_id, channel_id, message_id, emoji) do
    if pid = Nex.Agent.Channel.Registry.whereis(instance_id) do
      GenServer.cast(pid, {:add_reaction, channel_id, message_id, emoji})
    end

    :ok
  end

  @doc "Remove the bot's own reaction from a message. Fire-and-forget."
  @spec remove_reaction(String.t(), String.t(), String.t(), String.t()) :: :ok
  def remove_reaction(instance_id, channel_id, message_id, emoji) do
    if pid = Nex.Agent.Channel.Registry.whereis(instance_id) do
      GenServer.cast(pid, {:remove_reaction, channel_id, message_id, emoji})
    end

    :ok
  end

  @doc "Trigger the typing indicator in a channel. Fire-and-forget."
  @spec trigger_typing(String.t(), String.t()) :: :ok
  def trigger_typing(instance_id, channel_id) do
    if pid = Nex.Agent.Channel.Registry.whereis(instance_id) do
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
      sequence: nil,
      session_id: nil
    }

    Bus.subscribe(Nex.Agent.Outbound.topic_for_channel(instance_id))
    Bus.subscribe(:inbound_ack)
    Bus.subscribe(:task_complete)
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
    if instance_id == state.instance_id do
      _ = do_send(payload, state)
    end

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

      cond do
        clean_content == "" ->
          state

        not allowed?(parent_chat_id, state.allow_from) ->
          state

        is_dm ->
          publish_inbound(channel_id, author_id, clean_content, data, state,
            parent_chat_id: parent_chat_id
          )

          state

        is_thread ->
          publish_inbound(channel_id, author_id, clean_content, data, state,
            parent_chat_id: parent_chat_id
          )

          state

        mentions_bot ->
          case create_thread_from_message(channel_id, message_id, clean_content, state) do
            {:ok, thread_id} ->
              Logger.info("[Discord] Auto-created thread #{thread_id} for message #{message_id}")

              publish_inbound(thread_id, author_id, clean_content, data, state,
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

  defp publish_inbound(chat_id, author_id, content, data, state, opts) do
    origin_channel_id = Map.get(data, "channel_id")
    parent_chat_id = Keyword.get(opts, :parent_chat_id)

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
      media_refs: [],
      attachments: []
    })
  end

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
        |> render_discord_body(state)
        |> edit_interaction_response(application_id, token, state)
        |> case do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("[Discord] Interaction response failed: #{inspect(reason)}")
        end

      _ ->
        send_channel_message(channel_id, content, state)
    end
  end

  defp do_send(%{chat_id: channel_id, content: content}, state) do
    send_channel_message(to_string(channel_id || ""), content, state)
  end

  defp do_send(payload, _state) do
    Logger.error("[Discord] Invalid outbound payload: #{inspect(payload)}")
  end

  defp send_channel_message(channel_id, content, state) do
    content
    |> normalize_outbound_text()
    |> Enum.each(fn segment ->
      for body <- render_discord_bodies(segment, state) do
        case create_message(channel_id, body, %{}, state) do
          {:ok, _message_id} -> :ok
          {:error, reason} -> Logger.error("[Discord] Send failed: #{inspect(reason)}")
        end
      end
    end)
  end

  defp create_message(channel_id, content, metadata, state) do
    body = render_discord_body(content, state)
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
    body = render_discord_body(content, state)

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

  defp render_discord_bodies(content, state) when is_binary(content) do
    content
    |> DiscordRenderer.render_payload(show_table_as: state.show_table_as)
    |> discord_payload_to_bodies()
  end

  defp render_discord_bodies(content, state), do: [render_discord_body(content, state)]

  defp render_discord_body(%{} = body, _state) do
    content = Map.get(body, "content", Map.get(body, :content, ""))
    embeds = Map.get(body, "embeds", Map.get(body, :embeds, []))

    %{
      "content" => to_string(content || ""),
      "embeds" => if(is_list(embeds), do: embeds, else: [])
    }
  end

  defp render_discord_body(content, state) when is_binary(content) do
    content
    |> DiscordRenderer.render_payload(show_table_as: state.show_table_as)
    |> discord_payload_to_body()
  end

  defp render_discord_body(content, _state),
    do: %{"content" => to_string(content || ""), "embeds" => []}

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

      case default_http_delete(url, [{"authorization", discord_authorization(state.token)}]) do
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

      {:ok, %{status: 429, body: body}} ->
        retry_after = get_in(body, ["retry_after"]) || get_in(body, [:retry_after]) || 1
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

      {:ok, %{status: 429, body: body}} ->
        retry_after = get_in(body, ["retry_after"]) || get_in(body, [:retry_after]) || 1
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
