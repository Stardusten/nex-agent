defmodule Nex.Agent.Interface.Channel.Specs.Discord do
  @moduledoc false

  @behaviour Nex.Agent.Interface.Channel.Spec

  require Logger

  alias Nex.Agent.Channel.Discord
  alias Nex.Agent.Channel.Discord.StreamConverter
  alias Nex.Agent.Channel.Discord.StreamState

  @table_modes ~w(raw ascii embed)
  @stream_flush_ms 1000
  @placeholder_tick_ms 1_000
  @typing_heartbeat_ms 8_000
  @status_idle_ms 5_000
  @status_refresh_ms 10_000

  @impl true
  def type, do: "discord"

  @impl true
  def gateway_module, do: Nex.Agent.Channel.Discord

  @impl true
  def apply_defaults(instance) when is_map(instance) do
    instance
    |> Map.put("type", type())
    |> Map.put_new("streaming", false)
    |> Map.put("show_table_as", normalize_table_mode(Map.get(instance, "show_table_as")))
  end

  @impl true
  def validate_instance(instance, opts) when is_map(instance) do
    instance_id = Keyword.get(opts, :instance_id)

    diagnostics =
      if Map.get(instance, "enabled", false) == true and
           not present?(Map.get(instance, "token")) do
        [
          %{
            code: :missing_required_channel_field,
            field: "token",
            instance_id: instance_id,
            type: type(),
            message: "enabled discord channel requires token"
          }
        ]
      else
        []
      end

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  @impl true
  def runtime(instance) when is_map(instance) do
    %{
      "type" => type(),
      "streaming" => Map.get(instance, "streaming", false) == true,
      "show_table_as" => normalize_table_mode(Map.get(instance, "show_table_as"))
    }
  end

  @impl true
  def format_prompt(runtime, _opts) when is_map(runtime) do
    show_table_as = Map.get(runtime, "show_table_as", "ascii")
    streaming = if Map.get(runtime, "streaming", false) == true, do: "streaming", else: "single"

    """
    ## Discord Output Contract

    - Current channel IR: Discord markdown.
    - Delivery mode: #{streaming}.
    - Discord supports bold, italic, underline (`__text__`), strikethrough, headings `#`/`##`/`###` only, lists, quotes, inline code, fenced code blocks, links, spoiler tags, and `<newmsg/>`.
    - Use paragraphs, bullets, blockquotes, and bold standalone labels for lightweight sections; reserve headings for rare major sections.
    - For compact section labels such as `Good`, `Problems`, `If I changed it`, or `问题`, write a bold line like `**Problems**`, then continue with bullets or paragraphs.
    - Never output any line starting with `####`, `#####`, or `######`, and do not wrap plain emphasis or short concept contrasts in fenced `text` blocks.
    - Never output separator or horizontal-rule lines such as `---`, `___`, or `***`; Discord does not support them reliably.
    - Discord does not support image embeds (`![]()`) or HTML.
    - Markdown tables render as #{show_table_as} (`raw`, `ascii`, or `embed` channel setting).
    - `<newmsg/>` splits your reply into separate messages wherever it appears.
    """
    |> String.trim()
  end

  @impl true
  def im_profile, do: Nex.Agent.Interface.IMIR.Profiles.Discord.profile()

  @impl true
  def renderer, do: Nex.Agent.Interface.IMIR.Renderers.Discord

  @impl true
  def config_contract do
    %{
      "type" => type(),
      "label" => "Discord",
      "ui" => %{
        "summary" => "Discord Gateway bot channel.",
        "requires" => [
          "bot token or env var",
          "optional guild_id",
          "allow_from for access control"
        ]
      },
      "fields" => [
        "type",
        "enabled",
        "streaming",
        "token",
        "guild_id",
        "allow_from",
        "show_table_as"
      ],
      "secret_fields" => ["token"],
      "required_when_enabled" => ["token"],
      "defaults" => %{"streaming" => false, "show_table_as" => "ascii"},
      "options" => %{"show_table_as" => @table_modes}
    }
  end

  @impl true
  def start_stream(instance_id, chat_id, metadata, opts)
      when is_binary(instance_id) and is_binary(chat_id) and is_map(metadata) do
    Discord.trigger_typing(instance_id, chat_id)

    with {:ok, converter} <- StreamConverter.start(instance_id, chat_id, metadata) do
      parent = Keyword.get(opts, :parent, self())
      key = Keyword.get(opts, :key)

      thinking_timer_ref =
        Process.send_after(parent, {:channel_stream_timer, key, :thinking}, @placeholder_tick_ms)

      typing_timer_ref =
        Process.send_after(parent, {:channel_stream_timer, key, :typing}, @typing_heartbeat_ms)

      {:ok,
       %StreamState{
         converter: converter,
         thinking_timer_ref: thinking_timer_ref,
         typing_timer_ref: typing_timer_ref
       }}
    end
  end

  @impl true
  def handle_stream_event(
        %StreamState{pending_text: pending_text} = stream_state,
        {:text, chunk},
        opts
      )
      when is_binary(chunk) do
    updated =
      stream_state
      |> cancel_status_timer()
      |> Map.put(:pending_text, pending_text <> chunk)
      |> schedule_flush(opts)

    {:ok, updated}
  end

  def handle_stream_event(%StreamState{} = stream_state, :finish, _opts) do
    flush_converter(cancel_flush(stream_state))
  end

  def handle_stream_event(%StreamState{} = stream_state, {:error, _message}, _opts) do
    {:ok, stream_state}
  end

  def handle_stream_event(%StreamState{} = stream_state, _event, _opts), do: {:ok, stream_state}

  @impl true
  def handle_stream_timer(%StreamState{} = stream_state, :flush, opts) do
    stream_state
    |> flush_converter()
    |> case do
      {:ok, updated} -> {:ok, maybe_schedule_status(updated, opts)}
      other -> other
    end
  end

  def handle_stream_timer(
        %StreamState{converter: %{placeholder: true} = converter} = stream_state,
        :thinking,
        opts
      ) do
    case StreamConverter.update_thinking_timer(converter) do
      {:ok, updated_converter} ->
        parent = Keyword.get(opts, :parent, self())
        key = Keyword.get(opts, :key)

        timer_ref =
          Process.send_after(
            parent,
            {:channel_stream_timer, key, :thinking},
            @placeholder_tick_ms
          )

        {:ok,
         %{
           stream_state
           | converter: updated_converter,
             thinking_timer_ref: timer_ref
         }}
    end
  end

  def handle_stream_timer(%StreamState{} = stream_state, :thinking, _opts),
    do: {:ok, stream_state}

  def handle_stream_timer(%StreamState{converter: converter} = stream_state, :typing, opts) do
    stream_state = cancel_typing_timer(stream_state)
    Discord.trigger_typing(converter.instance_id, converter.chat_id)

    parent = Keyword.get(opts, :parent, self())
    key = Keyword.get(opts, :key)

    timer_ref =
      Process.send_after(parent, {:channel_stream_timer, key, :typing}, @typing_heartbeat_ms)

    {:ok, %{stream_state | typing_timer_ref: timer_ref}}
  end

  def handle_stream_timer(%StreamState{converter: converter} = stream_state, :status, opts) do
    stream_state = cancel_status_timer(stream_state)

    if StreamConverter.active_content?(converter) do
      case StreamConverter.refresh_working_status(converter) do
        {:ok, updated_converter} ->
          parent = Keyword.get(opts, :parent, self())
          key = Keyword.get(opts, :key)

          timer_ref =
            Process.send_after(parent, {:channel_stream_timer, key, :status}, @status_refresh_ms)

          {:ok,
           %{
             stream_state
             | converter: updated_converter,
               status_timer_ref: timer_ref
           }}

        {:error, reason} ->
          Logger.warning("[DiscordStream] status refresh failed: #{inspect(reason)}")
          {:ok, stream_state}
      end
    else
      {:ok, stream_state}
    end
  end

  def handle_stream_timer(%StreamState{} = stream_state, _timer, _opts), do: {:ok, stream_state}

  @impl true
  def finalize_stream(%StreamState{} = stream_state, result, _opts) do
    stream_state =
      stream_state
      |> cancel_flush()
      |> cancel_thinking_timer()
      |> cancel_typing_timer()
      |> cancel_status_timer()

    with {:ok, %StreamState{converter: flushed_converter}} <- flush_converter(stream_state) do
      finalize_fun =
        case result do
          {:ok, _value} -> &StreamConverter.finish/1
          {:error, message, _reason} -> &StreamConverter.fail(&1, message)
          {:error, message} -> &StreamConverter.fail(&1, format_reason(message))
        end

      case finalize_fun.(flushed_converter) do
        {:ok, _updated} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def cancel_stream(%StreamState{} = stream_state) do
    stream_state
    |> cancel_flush()
    |> cancel_thinking_timer()
    |> cancel_typing_timer()
    |> cancel_status_timer()

    :ok
  end

  @impl true
  def start_follow_up_typing(instance_id, chat_id, opts) do
    Discord.trigger_typing(instance_id, chat_id)
    follow_up_typing_timer(opts)
  end

  @impl true
  def handle_follow_up_typing(instance_id, chat_id, opts) do
    Discord.trigger_typing(instance_id, chat_id)
    follow_up_typing_timer(opts)
  end

  defp normalize_table_mode(mode) when is_binary(mode) do
    mode = mode |> String.trim() |> String.downcase()
    if mode in @table_modes, do: mode, else: "ascii"
  end

  defp normalize_table_mode(_mode), do: "ascii"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp schedule_flush(%StreamState{flush_timer_ref: nil} = stream_state, opts) do
    parent = Keyword.get(opts, :parent, self())
    key = Keyword.get(opts, :key)
    ref = Process.send_after(parent, {:channel_stream_timer, key, :flush}, @stream_flush_ms)
    %{stream_state | flush_timer_ref: ref}
  end

  defp schedule_flush(stream_state, _opts), do: stream_state

  defp cancel_flush(%StreamState{flush_timer_ref: nil} = stream_state), do: stream_state

  defp cancel_flush(%StreamState{flush_timer_ref: ref} = stream_state) do
    Process.cancel_timer(ref)
    %{stream_state | flush_timer_ref: nil}
  end

  defp cancel_thinking_timer(%StreamState{thinking_timer_ref: nil} = stream_state),
    do: stream_state

  defp cancel_thinking_timer(%StreamState{thinking_timer_ref: ref} = stream_state) do
    Process.cancel_timer(ref)
    %{stream_state | thinking_timer_ref: nil}
  end

  defp cancel_typing_timer(%StreamState{typing_timer_ref: nil} = stream_state),
    do: stream_state

  defp cancel_typing_timer(%StreamState{typing_timer_ref: ref} = stream_state) do
    Process.cancel_timer(ref)
    %{stream_state | typing_timer_ref: nil}
  end

  defp cancel_status_timer(%StreamState{status_timer_ref: nil} = stream_state),
    do: stream_state

  defp cancel_status_timer(%StreamState{status_timer_ref: ref} = stream_state) do
    Process.cancel_timer(ref)
    %{stream_state | status_timer_ref: nil}
  end

  defp maybe_schedule_status(
         %StreamState{converter: converter, status_timer_ref: nil} = stream_state,
         opts
       ) do
    if StreamConverter.active_content?(converter) do
      parent = Keyword.get(opts, :parent, self())
      key = Keyword.get(opts, :key)
      ref = Process.send_after(parent, {:channel_stream_timer, key, :status}, @status_idle_ms)
      %{stream_state | status_timer_ref: ref}
    else
      stream_state
    end
  end

  defp maybe_schedule_status(stream_state, _opts), do: stream_state

  defp flush_converter(%StreamState{pending_text: ""} = stream_state) do
    {:ok, %{stream_state | flush_timer_ref: nil}}
  end

  defp flush_converter(
         %StreamState{converter: converter, pending_text: pending_text} = stream_state
       ) do
    case StreamConverter.push_text(converter, pending_text) do
      {:ok, updated_converter} ->
        stream_state = %{
          stream_state
          | converter: updated_converter,
            pending_text: "",
            flush_timer_ref: nil
        }

        stream_state =
          if updated_converter.placeholder do
            stream_state
          else
            cancel_thinking_timer(stream_state)
          end

        {:ok, stream_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_up_typing_timer(opts) do
    parent = Keyword.get(opts, :parent, self())
    key = Keyword.get(opts, :key)
    Process.send_after(parent, {:channel_follow_up_typing_tick, key}, @typing_heartbeat_ms)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
