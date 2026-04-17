defmodule Nex.Agent.Channel.Feishu.StreamConverter do
  @moduledoc false

  require Logger

  alias Nex.Agent.Channel.Feishu

  @new_message_token "<newmsg/>"
  @code_fence "```"
  @placeholder_text "Thinking..."

  defstruct [
    :chat_id,
    :metadata,
    :active_card_id,
    :active_sequence,
    active_text: "",
    pending_buffer: "",
    current_line: "",
    in_code_block?: false,
    completed: false
  ]

  @type t :: %__MODULE__{
          chat_id: String.t(),
          metadata: map(),
          active_card_id: String.t() | nil,
          active_sequence: pos_integer() | nil,
          active_text: String.t(),
          pending_buffer: String.t(),
          current_line: String.t(),
          in_code_block?: boolean(),
          completed: boolean()
        }

  @spec start(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def start(chat_id, metadata) when is_binary(chat_id) and is_map(metadata) do
    state = %__MODULE__{
      chat_id: chat_id,
      metadata: metadata,
      active_card_id: nil,
      active_sequence: nil,
      active_text: "",
      pending_buffer: "",
      current_line: "",
      in_code_block?: false,
      completed: false
    }

    open_card(state, @placeholder_text)
  end

  @spec push_text(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def push_text(%__MODULE__{} = state, text_chunk) when is_binary(text_chunk) do
    trace(state, "push_text bytes=#{byte_size(text_chunk)} preview=#{inspect(String.slice(text_chunk, 0, 80))}")
    data = state.pending_buffer <> text_chunk

    {processable, pending_buffer} = split_processable(data)

    trace(
      state,
      "push_text_split processable_bytes=#{byte_size(processable)} pending_buffer_bytes=#{byte_size(pending_buffer)}"
    )

    with {:ok, state} <- consume(%{state | pending_buffer: ""}, processable, defer_new_message?: true) do
      {:ok, %{state | pending_buffer: state.pending_buffer <> pending_buffer}}
    end
  end

  @spec finish(t()) :: {:ok, t()} | {:error, term()}
  def finish(%__MODULE__{} = state) do
    trace(state, "finish pending_buffer_bytes=#{byte_size(state.pending_buffer)}")

    with {:ok, state} <-
           consume(%{state | pending_buffer: ""}, state.pending_buffer, defer_new_message?: false) do
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

  defp split_processable(""), do: {"", ""}

  defp split_processable(data) do
    suffix =
      [@new_message_token, @code_fence]
      |> Enum.reduce("", fn token, acc ->
        cond do
          String.ends_with?(data, token) ->
            acc

          true ->
            token
            |> token_prefixes()
            |> Enum.sort_by(&String.length/1, :desc)
            |> Enum.find(acc, fn prefix ->
              String.ends_with?(data, prefix)
            end)
        end
      end)

    if suffix == "" do
      {data, ""}
    else
      cut = String.length(data) - String.length(suffix)
      {String.slice(data, 0, cut), suffix}
    end
  end

  defp consume(state, "", _opts), do: {:ok, state}

  defp consume(%__MODULE__{} = state, binary, opts) when is_binary(binary) do
    do_consume(binary, state, "", opts)
  end

  defp do_consume("", state, segment, _opts), do: append_segment(state, segment)

  defp do_consume(string, %__MODULE__{} = state, segment, opts) when is_binary(string) do
    cond do
      String.starts_with?(string, @code_fence) ->
        rest = String.replace_prefix(string, @code_fence, "")

        do_consume(
          rest,
          %{state | in_code_block?: not state.in_code_block?},
          segment <> @code_fence,
          opts
        )

      not state.in_code_block? ->
        case consume_new_message_boundary(string, state, segment, opts) do
          {:match, cleaned_segment, rest} ->
            trace(
              state,
              "newmsg_match segment_bytes=#{byte_size(cleaned_segment)} rest_preview=#{inspect(String.slice(rest, 0, 80))}"
            )

            with {:ok, state} <- append_segment(state, cleaned_segment) do
              maybe_defer_after_new_message(state, rest, opts)
            end

          :no_match ->
            {grapheme, rest} = String.next_grapheme(string)
            do_consume(rest, state, segment <> grapheme, opts)
        end

      true ->
        {grapheme, rest} = String.next_grapheme(string)
        do_consume(rest, state, segment <> grapheme, opts)
    end
  end

  defp consume_new_message_boundary(string, state, segment, opts) do
    case Regex.run(~r/\A[ \t]*<newmsg\/>[ \t]*(?:\n|$)/, string) do
      [match] ->
        if separator_line_start?(state, segment) do
          rest = String.replace_prefix(string, match, "")
          rest = String.trim_leading(rest, "\n")

          trace(
            state,
            "newmsg_boundary defer=#{Keyword.get(opts, :defer_new_message?, false)} rest_bytes=#{byte_size(rest)}"
          )

          {:match, strip_separator_indent(segment), rest}
        else
          :no_match
        end

      _ ->
        :no_match
    end
  end

  defp separator_line_start?(state, segment) do
    line_prefix = line_prefix_for_segment(state, segment)
    line_prefix == nil or Regex.match?(~r/^[ \t]*$/, line_prefix)
  end

  defp line_prefix_for_segment(%__MODULE__{current_line: current_line}, "") do
    current_line
  end

  defp line_prefix_for_segment(%__MODULE__{current_line: current_line}, segment) do
    case String.split(segment, "\n") do
      [single] ->
        current_line <> single

      parts ->
        List.last(parts)
    end
  end

  defp strip_separator_indent(segment) do
    case String.split(segment, "\n") do
      [_single] ->
        String.trim_trailing(segment)

      parts ->
        {head, [last]} = Enum.split(parts, length(parts) - 1)
        Enum.join(head ++ [String.trim_trailing(last)], "\n")
    end
  end

  defp token_prefixes(token) do
    max_prefix_length =
      case token do
        @new_message_token -> String.length(token)
        _ -> String.length(token) - 1
      end

    1..max_prefix_length
    |> Enum.map(&String.slice(token, 0, &1))
  end

  defp maybe_defer_after_new_message(%__MODULE__{} = state, "", opts) do
    with {:ok, state} <- force_flush_active_card_animation(state) do
      do_consume("", rotate_card(state), "", opts)
    end
  end

  defp maybe_defer_after_new_message(%__MODULE__{} = state, rest, opts) do
    if Keyword.get(opts, :defer_new_message?, false) do
      trace(
        state,
        "newmsg_defer rest_bytes=#{byte_size(rest)} rest_preview=#{inspect(String.slice(rest, 0, 80))}"
      )

      with {:ok, state} <- force_flush_active_card_animation(state) do
        {:ok, %{rotate_card(state) | pending_buffer: state.pending_buffer <> rest}}
      end
    else
      with {:ok, state} <- force_flush_active_card_animation(state) do
        do_consume(rest, rotate_card(state), "", opts)
      end
    end
  end

  defp append_segment(state, ""), do: {:ok, state}

  defp append_segment(%__MODULE__{active_card_id: nil} = state, segment) do
    segment =
      if state.active_text == "" and String.trim(segment) == "" do
        ""
      else
        String.trim_leading(segment, "\n")
      end

    if segment == "" do
      {:ok, state}
    else
      trace(state, "append_segment_open bytes=#{byte_size(segment)} preview=#{inspect(String.slice(segment, 0, 80))}")
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

    with {:ok, state} <- put_active_text(state, next_text) do
      {:ok, %{state | current_line: next_current_line(next_text)}}
    end
  end

  defp rotate_card(%__MODULE__{} = state) do
    trace(state, "rotate_card previous_card_id=#{inspect(state.active_card_id)} previous_len=#{byte_size(state.active_text)}")
    %{
      state
      | active_card_id: nil,
        active_sequence: nil,
        active_text: "",
        current_line: "",
        in_code_block?: false
    }
  end

  defp open_card(%__MODULE__{} = state, content) do
    trace(state, "open_card content_len=#{byte_size(content)} preview=#{inspect(String.slice(content, 0, 80))}")

    with {:ok, %{card_id: card_id}} <-
           Feishu.open_stream_card(state.chat_id, content, state.metadata) do
      trace(state, "open_card_done card_id=#{card_id}")
      {:ok,
       %{
         state
         | active_card_id: card_id,
           active_sequence: 1,
           active_text: content,
           current_line: next_current_line(content),
           in_code_block?: false
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

    case Feishu.update_card(state.active_card_id, text, next_sequence) do
      :ok ->
        {:ok, %{state | active_text: text, active_sequence: next_sequence}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp force_flush_active_card_animation(%__MODULE__{active_card_id: nil} = state), do: {:ok, state}

  defp force_flush_active_card_animation(%__MODULE__{} = state) do
    next_sequence = max((state.active_sequence || 0) + 1, 2)

    trace(
      state,
      "dummy_update_card card_id=#{inspect(state.active_card_id)} sequence=#{next_sequence} content_len=#{byte_size(state.active_text)}"
    )

    case Feishu.update_card(state.active_card_id, state.active_text, next_sequence) do
      :ok ->
        {:ok, %{state | active_sequence: next_sequence}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_current_line(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> List.last()
  end

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
