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
    data = state.pending_buffer <> text_chunk

    if String.contains?(data, @new_message_token) do
      Logger.info(
        "[FeishuStreamConverter] push_text newmsg data=#{inspect(data)} active_text=#{inspect(state.active_text)} pending_buffer=#{inspect(state.pending_buffer)} in_code=#{state.in_code_block?}"
      )
    end

    {processable, pending_buffer} = split_processable(data)

    with {:ok, state} <- consume(state, processable) do
      {:ok, reconcile_state(%{state | pending_buffer: pending_buffer})}
    end
  end

  @spec finish(t()) :: {:ok, t()} | {:error, term()}
  def finish(%__MODULE__{} = state) do
    if String.contains?(state.pending_buffer, @new_message_token) do
      Logger.info(
        "[FeishuStreamConverter] finish pending_buffer=#{inspect(state.pending_buffer)} active_text=#{inspect(state.active_text)} in_code=#{state.in_code_block?}"
      )
    end

    with {:ok, state} <- consume(%{state | pending_buffer: ""}, state.pending_buffer) do
      {:ok, reconcile_state(%{state | completed: true})}
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

  defp consume(state, ""), do: {:ok, state}

  defp consume(%__MODULE__{} = state, binary) when is_binary(binary) do
    do_consume(binary, state, "")
  end

  defp do_consume("", state, segment), do: append_segment(state, segment)

  defp do_consume(string, %__MODULE__{} = state, segment) when is_binary(string) do
    cond do
      String.starts_with?(string, @code_fence) ->
        rest = String.replace_prefix(string, @code_fence, "")

        do_consume(
          rest,
          %{state | in_code_block?: not state.in_code_block?},
          segment <> @code_fence
        )

      not state.in_code_block? ->
        case consume_new_message_boundary(string, state, segment) do
          {:match, cleaned_segment, rest} ->
            with {:ok, state} <- append_segment(state, cleaned_segment) do
              do_consume(rest, rotate_card(state), "")
            end

          :no_match ->
            {grapheme, rest} = String.next_grapheme(string)
            do_consume(rest, state, segment <> grapheme)
        end

      true ->
        {grapheme, rest} = String.next_grapheme(string)
        do_consume(rest, state, segment <> grapheme)
    end
  end

  defp consume_new_message_boundary(string, state, segment) do
    case Regex.run(~r/\A[ \t]*<newmsg\/>[ \t]*(?:\n|$)/, string) do
      [match] ->
        if separator_line_start?(state, segment) do
          Logger.info(
            "[FeishuStreamConverter] matched newmsg segment=#{inspect(segment)} string=#{inspect(string)} active_text=#{inspect(state.active_text)}"
          )

          rest = String.replace_prefix(string, match, "")
          {:match, strip_separator_indent(segment), String.trim_leading(rest, "\n")}
        else
          Logger.info(
            "[FeishuStreamConverter] rejected newmsg-not-line-start segment=#{inspect(segment)} string=#{inspect(string)} active_text=#{inspect(state.active_text)}"
          )

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
    1..(String.length(token) - 1)
    |> Enum.map(&String.slice(token, 0, &1))
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

    with {:ok, state} <- put_active_text(state, next_text) do
      {:ok, %{state | current_line: next_current_line(next_text)}}
    end
  end

  defp rotate_card(%__MODULE__{} = state) do
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
    with {:ok, %{card_id: card_id}} <-
           Feishu.open_stream_card(state.chat_id, content, state.metadata) do
      {:ok,
       %{
         state
         | active_card_id: card_id,
           active_sequence: 1,
           active_text: content,
           current_line: next_current_line(content)
       }}
    end
  end

  defp put_active_text(%__MODULE__{active_card_id: nil} = state, text), do: open_card(state, text)

  defp put_active_text(%__MODULE__{} = state, text) do
    next_sequence = max((state.active_sequence || 0) + 1, 2)

    case Feishu.update_card(state.active_card_id, text, next_sequence) do
      :ok ->
        {:ok, %{state | active_text: text, active_sequence: next_sequence}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_current_line(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> List.last()
  end

  defp reconcile_state(%__MODULE__{} = state) do
    %{state | current_line: next_current_line(state.active_text), in_code_block?: in_code_block?(state.active_text)}
  end

  defp in_code_block?(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(false, fn line, in_code? ->
      if String.starts_with?(line, @code_fence), do: not in_code?, else: in_code?
    end)
  end
end
