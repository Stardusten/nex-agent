defmodule Nex.Agent.Channel.Feishu.StreamConverter do
  @moduledoc false

  require Logger

  alias Nex.Agent.Channel.Feishu

  @new_message_token "<newmsg/>"
  @placeholder_text "Thinking..."

  # Maximum bytes of a partial <newmsg/> prefix that could sit at the end of a chunk.
  # "<newmsg/>" is 9 bytes; we hold back up to 8 bytes (incomplete prefix).
  @newmsg_holdback_bytes byte_size(@new_message_token) - 1

  defstruct [
    :instance_id,
    :chat_id,
    :metadata,
    :active_card_id,
    :active_sequence,
    active_text: "",
    pending_buffer: "",
    completed: false
  ]

  @type t :: %__MODULE__{
          chat_id: String.t(),
          instance_id: String.t(),
          metadata: map(),
          active_card_id: String.t() | nil,
          active_sequence: pos_integer() | nil,
          active_text: String.t(),
          pending_buffer: String.t(),
          completed: boolean()
        }

  @spec start(String.t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def start(instance_id, chat_id, metadata)
      when is_binary(instance_id) and is_binary(chat_id) and is_map(metadata) do
    state = %__MODULE__{
      instance_id: instance_id,
      chat_id: chat_id,
      metadata: metadata
    }

    open_card(state, @placeholder_text)
  end

  @spec push_text(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def push_text(%__MODULE__{} = state, text_chunk) when is_binary(text_chunk) do
    trace(
      state,
      "push_text bytes=#{byte_size(text_chunk)} preview=#{inspect(String.slice(text_chunk, 0, 80))}"
    )

    data = state.pending_buffer <> text_chunk
    {processable, holdback} = split_processable(data)

    trace(
      state,
      "push_text_split processable_bytes=#{byte_size(processable)} holdback_bytes=#{byte_size(holdback)}"
    )

    with {:ok, state} <- consume(%{state | pending_buffer: ""}, processable) do
      {:ok, %{state | pending_buffer: state.pending_buffer <> holdback}}
    end
  end

  @empty_message_text "_(Empty Message)_"

  @spec finish(t()) :: {:ok, t()} | {:error, term()}
  def finish(%__MODULE__{} = state) do
    trace(state, "finish pending_buffer_bytes=#{byte_size(state.pending_buffer)}")

    with {:ok, state} <- consume(%{state | pending_buffer: ""}, state.pending_buffer) do
      # If still showing "Thinking..." (LLM returned no text), replace with empty message hint
      state =
        if state.active_text == @placeholder_text and state.active_sequence == 1 do
          case put_active_text(state, @empty_message_text) do
            {:ok, updated} -> updated
            {:error, _} -> state
          end
        else
          state
        end

      close_active_card(state)
      {:ok, %{state | completed: true, pending_buffer: ""}}
    end
  end

  @spec fail(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def fail(%__MODULE__{} = state, message) when is_binary(message) do
    message = String.trim(message)

    cond do
      message == "" ->
        {:ok, %{state | completed: true}}

      state.active_card_id == nil ->
        with {:ok, state} <- open_card(state, "Error: " <> message) do
          {:ok, %{state | completed: true}}
        end

      true ->
        trace(state, "fail message=#{inspect(message)}")

        text =
          case String.trim(state.active_text) do
            "" -> "Error: " <> message
            _ -> state.active_text <> "\n\nError: " <> message
          end

        with {:ok, state} <- put_active_text(state, text) do
          {:ok, %{state | completed: true}}
        end
    end
  end

  # ── consume: split by <newmsg/> and process each segment ──────────────

  defp consume(state, ""), do: {:ok, state}

  defp consume(state, data) do
    case String.split(data, @new_message_token, parts: 2) do
      [single] ->
        append_segment(state, single)

      [before, after_text] ->
        trace(
          state,
          "newmsg_match before_bytes=#{byte_size(before)} after_bytes=#{byte_size(after_text)}"
        )

        with {:ok, state} <- append_segment(state, String.trim(before)),
             {:ok, state} <- rotate_card(state) do
          consume(state, String.trim(after_text))
        end
    end
  end

  # ── split_processable: hold back incomplete <newmsg/> at chunk boundary ─

  defp split_processable(""), do: {"", ""}

  defp split_processable(data) do
    data_len = byte_size(data)
    # Check if data ends with an incomplete prefix of <newmsg/>.
    tail_start = max(data_len - @newmsg_holdback_bytes, 0)
    tail = binary_part(data, tail_start, data_len - tail_start)

    # If the tail contains a partial "<newmsg" prefix that hasn't completed,
    # hold it back. We check for any proper prefix of the token that appears
    # at the end of the tail (but not the full token — that can pass through).
    holdback = find_incomplete_newmsg_suffix(tail)

    if holdback == "" do
      {data, ""}
    else
      cut = data_len - byte_size(holdback)
      {binary_part(data, 0, cut), holdback}
    end
  end

  defp find_incomplete_newmsg_suffix(tail) do
    max_check = min(byte_size(tail), byte_size(@new_message_token) - 1)

    Enum.find_value(max_check..1//-1, "", fn len ->
      prefix = binary_part(@new_message_token, 0, len)

      if String.ends_with?(tail, prefix) do
        prefix
      else
        nil
      end
    end)
  end

  # ── card lifecycle ──────────────────────────────────────────────────────

  defp append_segment(state, ""), do: {:ok, state}

  defp append_segment(%__MODULE__{active_card_id: nil} = state, segment) do
    segment =
      if state.active_text == "" do
        String.trim_leading(segment, "\n")
      else
        segment
      end

    if segment == "" do
      {:ok, state}
    else
      trace(
        state,
        "append_segment_open bytes=#{byte_size(segment)} preview=#{inspect(String.slice(segment, 0, 80))}"
      )

      open_card(state, segment)
    end
  end

  defp append_segment(%__MODULE__{} = state, segment) do
    next_text =
      if state.active_text == @placeholder_text and state.active_sequence == 1 do
        segment
      else
        state.active_text <> segment
      end

    trace(
      state,
      "append_segment_update add_bytes=#{byte_size(segment)} next_len=#{byte_size(next_text)}"
    )

    put_active_text(state, next_text)
  end

  defp rotate_card(%__MODULE__{} = state) do
    trace(
      state,
      "rotate_card previous_card_id=#{inspect(state.active_card_id)} previous_len=#{byte_size(state.active_text)}"
    )

    close_active_card(state)

    {:ok,
     %{
       state
       | active_card_id: nil,
         active_sequence: nil,
         active_text: ""
     }}
  end

  defp open_card(%__MODULE__{} = state, content) do
    trace(
      state,
      "open_card content_len=#{byte_size(content)} preview=#{inspect(String.slice(content, 0, 80))}"
    )

    with {:ok, %{card_id: card_id}} <-
           Feishu.open_stream_card(state.instance_id, state.chat_id, content, state.metadata) do
      trace(state, "open_card_done card_id=#{card_id}")

      {:ok,
       %{
         state
         | active_card_id: card_id,
           active_sequence: 1,
           active_text: content
       }}
    end
  end

  defp put_active_text(%__MODULE__{active_card_id: nil} = state, text), do: open_card(state, text)

  defp put_active_text(%__MODULE__{} = state, text) do
    next_sequence = max((state.active_sequence || 0) + 1, 2)

    trace(
      state,
      "update_card card_id=#{inspect(state.active_card_id)} sequence=#{next_sequence} content_len=#{byte_size(text)}"
    )

    case Feishu.update_card(state.instance_id, state.active_card_id, text, next_sequence) do
      :ok ->
        {:ok, %{state | active_text: text, active_sequence: next_sequence}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── streaming mode lifecycle ────────────────────────────────────────────

  defp close_active_card(%__MODULE__{active_card_id: nil}), do: :ok

  defp close_active_card(%__MODULE__{active_card_id: card_id} = state) do
    trace(state, "close_streaming_mode card_id=#{inspect(card_id)}")

    case Feishu.close_streaming_mode(state.instance_id, card_id) do
      :ok ->
        :ok

      {:error, reason} ->
        trace(
          state,
          "close_streaming_mode_failed card_id=#{inspect(card_id)} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  # ── trace ────────────────────────────────────────────────────────────────

  defp trace(%__MODULE__{metadata: metadata}, message) do
    trace_id = Map.get(metadata || %{}, "_feishu_stream_trace_id")
    started_at_ms = Map.get(metadata || %{}, "_feishu_stream_started_at_ms")

    elapsed_ms =
      case started_at_ms do
        value when is_integer(value) -> System.monotonic_time(:millisecond) - value
        _ -> 0
      end

    Logger.info("[FeishuStream][#{trace_id}][+#{elapsed_ms}ms] #{message}")
  end
end
