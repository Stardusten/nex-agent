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
        "guild_id" => nil               # Optional: restrict to a guild
      }
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config, HTTP}
  alias Nex.Agent.Command.Invocation
  alias Nex.Agent.Channel.Discord.WSClient
  alias Nex.Agent.Inbound.Envelope
  alias Nex.Agent.IMIR.Renderers.Discord, as: DiscordRenderer
  alias Nex.Agent.IMIR.Text, as: IMText

  @discord_api "https://discord.com/api/v10"
  @gateway_url "wss://gateway.discord.gg/?v=10&encoding=json"
  @heartbeat_jitter 0.9
  @reconnect_delay_ms 5_000
  @eyes_emoji "👀"
  @done_emoji "✅"
  @error_emoji "❌"

  @type thread_meta :: %{
          parent_id: String.t(),
          guild_id: String.t() | nil
        }

  defstruct [
    :token,
    :allow_from,
    :guild_id,
    :enabled,
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
          token: String.t(),
          allow_from: [String.t()],
          guild_id: String.t() | nil,
          enabled: boolean(),
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
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec send_message(String.t(), String.t(), map()) :: :ok
  def send_message(channel_id, content, metadata \\ %{}) do
    Bus.publish(:discord_outbound, %{
      chat_id: to_string(channel_id),
      content: content,
      metadata: metadata
    })
  end

  @doc "Send a Discord message synchronously and return the created message_id."
  @spec deliver_message(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def deliver_message(channel_id, content, metadata \\ %{}) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:deliver_message, channel_id, content, metadata}, 15_000)
    else
      {:error, :discord_not_running}
    end
  end

  @doc "Edit an existing Discord message synchronously."
  @spec update_message(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_message(channel_id, message_id, content, metadata \\ %{}) do
    if Process.whereis(__MODULE__) do
      GenServer.call(
        __MODULE__,
        {:update_message, channel_id, message_id, content, metadata},
        15_000
      )
    else
      {:error, :discord_not_running}
    end
  end

  @doc "Add a Unicode emoji reaction to a message. Fire-and-forget."
  @spec add_reaction(String.t(), String.t(), String.t()) :: :ok
  def add_reaction(channel_id, message_id, emoji) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:add_reaction, channel_id, message_id, emoji})
    end

    :ok
  end

  @doc "Remove the bot's own reaction from a message. Fire-and-forget."
  @spec remove_reaction(String.t(), String.t(), String.t()) :: :ok
  def remove_reaction(channel_id, message_id, emoji) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:remove_reaction, channel_id, message_id, emoji})
    end

    :ok
  end

  @doc "Trigger the typing indicator in a channel. Fire-and-forget."
  @spec trigger_typing(String.t()) :: :ok
  def trigger_typing(channel_id) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:trigger_typing, channel_id})
    end

    :ok
  end

  # Server

  @impl true
  def init(opts) do
    _ = Application.ensure_all_started(:req)
    _ = Application.ensure_all_started(:mint)

    config = Keyword.get(opts, :config, Config.load())
    discord = Config.discord(config)

    state = %__MODULE__{
      token: Map.get(discord, "token", ""),
      allow_from: Config.discord_allow_from(config),
      guild_id: Map.get(discord, "guild_id"),
      enabled: Config.discord_enabled?(config),
      http_post_fun: Keyword.get(opts, :http_post_fun, &default_http_post/3),
      http_patch_fun: Keyword.get(opts, :http_patch_fun, &default_http_patch/3),
      sequence: nil,
      session_id: nil
    }

    Bus.subscribe(:discord_outbound)
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
        Logger.error("[Discord] Gateway authentication failed (close code 4004), disabling channel")
        {:noreply, %{state | enabled: false}}

      {:remote, 1000, _message} ->
        Logger.info("[Discord] WebSocket closed normally reason=#{inspect(reason)}, reconnecting...")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}

      _ ->
        Logger.warning("[Discord] WebSocket closed reason=#{inspect(reason)}, reconnecting...")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:bus_message, :discord_outbound, payload}, state) when is_map(payload) do
    _ = do_send(payload, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:bus_message, :inbound_ack, %{channel: "discord"} = payload}, state) do
    message_id = payload.message_id
    reaction_channel = payload[:origin_channel_id] || payload.chat_id

    if is_binary(message_id) and message_id != "" do
      do_add_reaction(reaction_channel, message_id, @eyes_emoji, state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:bus_message, :task_complete, %{channel: "discord"} = payload}, state) do
    message_id = payload.message_id
    reaction_channel = payload[:origin_channel_id] || payload.chat_id

    if is_binary(message_id) and message_id != "" do
      do_remove_reaction(reaction_channel, message_id, @eyes_emoji, state)
      final_emoji = if payload.status == :ok, do: @done_emoji, else: @error_emoji
      do_add_reaction(reaction_channel, message_id, final_emoji, state)
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

  defp handle_gateway_event(%{"op" => 0, "t" => "INTERACTION_CREATE", "d" => data, "s" => seq}, state) do
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
      Logger.info("[Discord] GUILD_CREATE guild=#{guild_id} cached #{map_size(thread_parents)} thread(s)")
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

      allowed_channel_id =
        thread_parent_id(thread_meta) || Map.get(data, "parent_id") || channel_id

      cond do
        clean_content == "" ->
          state

        not allowed?(allowed_channel_id, state.allow_from) ->
          state

        is_dm ->
          publish_inbound(channel_id, author_id, clean_content, data, state)
          state

        is_thread ->
          publish_inbound(channel_id, author_id, clean_content, data, state)
          state

        mentions_bot ->
          case create_thread_from_message(channel_id, message_id, clean_content, state) do
            {:ok, thread_id} ->
              Logger.info("[Discord] Auto-created thread #{thread_id} for message #{message_id}")
              publish_inbound(thread_id, author_id, clean_content, data, state)
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
              Logger.warning("[Discord] Failed to create thread: #{inspect(reason)}, replying in channel")
              publish_inbound(channel_id, author_id, clean_content, data, state)
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
    allowed_channel_id = thread_parent_id(thread_meta) || channel_id

    if allowed?(allowed_channel_id, state.allow_from) do
      Bus.publish(:inbound, %Envelope{
        channel: "discord",
        chat_id: to_string(channel_id),
        sender_id: to_string(author_id),
        text: raw,
        command: %Invocation{name: name, args: args, raw: raw, source: :native},
        message_type: :text,
        raw: data,
        metadata: %{
          "guild_id" => guild_id,
          "application_id" => Map.get(data, "application_id"),
          "interaction_id" => Map.get(data, "id"),
          "interaction_token" => Map.get(data, "token"),
          "origin_channel_id" => channel_id,
          "username" =>
            get_in(data, ["member", "user", "username"]) || get_in(data, ["user", "username"])
        },
        media_refs: [],
        attachments: []
      })
    end
  end

  defp interaction_option_values(%{"value" => value}) when is_binary(value), do: [value]
  defp interaction_option_values(%{"value" => value}) when is_integer(value), do: [Integer.to_string(value)]
  defp interaction_option_values(%{"value" => value}) when is_float(value), do: [to_string(value)]
  defp interaction_option_values(%{"value" => value}) when is_boolean(value), do: [to_string(value)]
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

  defp publish_inbound(chat_id, author_id, content, data, _state) do
    origin_channel_id = Map.get(data, "channel_id")

    Bus.publish(:inbound, %Envelope{
      channel: "discord",
      chat_id: to_string(chat_id),
      sender_id: to_string(author_id),
      text: content,
      message_type: :text,
      raw: data,
      metadata: %{
        "guild_id" => Map.get(data, "guild_id"),
        "message_id" => Map.get(data, "id"),
        "origin_channel_id" => origin_channel_id,
        "username" => get_in(data, ["author", "username"])
      },
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
        |> render_discord_content()
        |> edit_interaction_response(application_id, token, state)
        |> case do
          :ok -> :ok
          {:error, reason} -> Logger.error("[Discord] Interaction response failed: #{inspect(reason)}")
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
      for chunk <- chunk_message(segment, 2000) do
        case create_message(channel_id, chunk, %{}, state) do
          {:ok, _message_id} -> :ok
          {:error, reason} -> Logger.error("[Discord] Send failed: #{inspect(reason)}")
        end
      end
    end)
  end

  defp create_message(channel_id, content, metadata, state) do
    content = render_discord_content(content)

    with :ok <- validate_outbound_message(channel_id, content, state),
         {:ok, response} <-
           state.http_post_fun.(
             "#{@discord_api}/channels/#{channel_id}/messages",
             %{"content" => content},
             request_headers(metadata, state)
           ) do
      case Map.get(response, "id") || Map.get(response, :id) do
        id when is_binary(id) and id != "" -> {:ok, id}
        _ -> {:error, {:missing_message_id, response}}
      end
    end
  end

  defp edit_message(channel_id, message_id, content, metadata, state) do
    content = render_discord_content(content)

    with :ok <- validate_outbound_message(channel_id, content, state),
         true <- is_binary(message_id) and message_id != "" or {:error, :invalid_message_id},
         {:ok, _response} <-
           state.http_patch_fun.(
             "#{@discord_api}/channels/#{channel_id}/messages/#{message_id}",
             %{"content" => content},
             request_headers(metadata, state)
           ) do
      :ok
    end
  end

  defp render_discord_content(content) when is_binary(content), do: DiscordRenderer.render_text(content)
  defp render_discord_content(content), do: content

  defp validate_outbound_message(channel_id, content, state) do
    cond do
      not is_binary(channel_id) or channel_id == "" ->
        {:error, :invalid_channel_id}

      not is_binary(content) or String.trim(content) == "" ->
        {:error, :invalid_content}

      state.token in [nil, ""] ->
        {:error, :missing_token}

      true ->
        :ok
    end
  end

  defp normalize_outbound_text(content) when is_binary(content) do
    content
    |> IMText.split_messages()
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_outbound_text(_content), do: []

  defp request_headers(_metadata, state) do
    [{"authorization", discord_authorization(state.token)}]
  end

  defp interaction_response_token(metadata) when is_map(metadata) do
    Map.get(metadata, "interaction_token") || Map.get(metadata, :interaction_token)
  end

  defp interaction_application_id(metadata) when is_map(metadata) do
    Map.get(metadata, "application_id") || Map.get(metadata, :application_id)
  end

  defp edit_interaction_response(content, application_id, token, state)
       when is_binary(application_id) and application_id != "" do
    state.http_patch_fun.(
      "#{@discord_api}/webhooks/#{application_id}/#{token}/messages/@original",
      %{"content" => content},
      request_headers(%{}, state)
    )
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp edit_interaction_response(_content, _application_id, _token, _state),
    do: {:error, :missing_application_id}

  defp chunk_message(text, max_len) do
    if String.length(text) <= max_len do
      [text]
    else
      {chunk, rest} = String.split_at(text, max_len)
      [chunk | chunk_message(rest, max_len)]
    end
  end

  # Reaction & typing helpers

  defp do_add_reaction(channel_id, message_id, emoji, state) do
    Task.start(fn ->
      encoded_emoji = URI.encode(emoji)
      url = "#{@discord_api}/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded_emoji}/@me"

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
      url = "#{@discord_api}/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded_emoji}/@me"

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
