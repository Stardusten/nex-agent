defmodule Nex.Agent.Channel.Discord.StreamConverter do
  @moduledoc false

  require Logger

  alias Nex.Agent.Channel.Discord

  @new_message_token "<newmsg/>"
  @newmsg_holdback_bytes byte_size(@new_message_token) - 1
  @max_message_length 2000
  @placeholder_text "🤔 Thinking..."

  defstruct [
    :instance_id,
    :chat_id,
    :metadata,
    :current_message_id,
    :started_at,
    :status_text,
    active_text: "",
    pending_buffer: "",
    placeholder: true,
    completed: false
  ]

  @type t :: %__MODULE__{
          chat_id: String.t(),
          instance_id: String.t(),
          metadata: map(),
          current_message_id: String.t() | nil,
          started_at: integer() | nil,
          status_text: String.t() | nil,
          active_text: String.t(),
          pending_buffer: String.t(),
          placeholder: boolean(),
          completed: boolean()
        }

  @spec start(String.t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def start(instance_id, chat_id, metadata)
      when is_binary(instance_id) and is_binary(chat_id) and is_map(metadata) do
    state = %__MODULE__{
      instance_id: instance_id,
      chat_id: chat_id,
      metadata: metadata,
      started_at: System.monotonic_time(:second)
    }

    # Send the initial "Thinking..." placeholder message
    case Discord.deliver_message(instance_id, chat_id, @placeholder_text, metadata) do
      {:ok, message_id} ->
        {:ok,
         %{
           state
           | current_message_id: message_id,
             active_text: @placeholder_text,
             placeholder: true
         }}

      {:error, reason} ->
        Logger.warning("[DiscordStream] Failed to send thinking placeholder: #{inspect(reason)}")
        # Still return ok — we can work without the placeholder
        {:ok, state}
    end
  end

  @doc "Update the thinking placeholder with elapsed time. No-op if real text has arrived."
  @spec update_thinking_timer(t()) :: {:ok, t()}
  def update_thinking_timer(%__MODULE__{placeholder: false} = state), do: {:ok, state}
  def update_thinking_timer(%__MODULE__{current_message_id: nil} = state), do: {:ok, state}
  def update_thinking_timer(%__MODULE__{completed: true} = state), do: {:ok, state}

  def update_thinking_timer(%__MODULE__{placeholder: true, started_at: started_at} = state)
      when is_integer(started_at) do
    elapsed = System.monotonic_time(:second) - started_at
    text = "🤔 Thinking... (#{elapsed}s)"

    case update_current_message(state, text) do
      {:ok, updated} -> {:ok, updated}
      {:error, _reason} -> {:ok, state}
    end
  end

  def update_thinking_timer(%__MODULE__{} = state), do: {:ok, state}

  @doc "Show or refresh the temporary working status under already-visible content."
  @spec refresh_working_status(t()) :: {:ok, t()}
  def refresh_working_status(%__MODULE__{completed: true} = state), do: {:ok, state}
  def refresh_working_status(%__MODULE__{placeholder: true} = state), do: {:ok, state}
  def refresh_working_status(%__MODULE__{current_message_id: nil} = state), do: {:ok, state}

  def refresh_working_status(%__MODULE__{} = state) do
    if active_content?(state) do
      elapsed = elapsed_seconds(state)
      update_status_text(state, "_Still working... #{elapsed}s_")
    else
      {:ok, state}
    end
  end

  @doc "Remove any temporary working status from the current Discord message."
  @spec clear_working_status(t()) :: {:ok, t()} | {:error, term()}
  def clear_working_status(%__MODULE__{status_text: nil} = state), do: {:ok, state}
  def clear_working_status(%__MODULE__{status_text: ""} = state), do: {:ok, state}

  def clear_working_status(%__MODULE__{} = state) do
    patch_current_message(state, %{state | status_text: nil})
  end

  @spec active_content?(t()) :: boolean()
  def active_content?(%__MODULE__{
        completed: false,
        placeholder: false,
        current_message_id: message_id,
        active_text: text
      })
      when is_binary(message_id) and is_binary(text) do
    String.trim(text) != ""
  end

  def active_content?(%__MODULE__{}), do: false

  @spec push_text(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def push_text(%__MODULE__{} = state, text_chunk) when is_binary(text_chunk) do
    data = state.pending_buffer <> text_chunk
    {processable, holdback} = split_processable(data)

    with {:ok, state} <- consume(%{state | pending_buffer: ""}, processable) do
      {:ok, %{state | pending_buffer: state.pending_buffer <> holdback}}
    end
  end

  @empty_message_text "_(Empty Message)_"

  @spec finish(t()) :: {:ok, t()} | {:error, term()}
  def finish(%__MODULE__{} = state) do
    with {:ok, state} <- clear_working_status(state),
         {:ok, state} <- consume(%{state | pending_buffer: ""}, state.pending_buffer) do
      # If still on the placeholder (LLM returned no text), show empty message hint
      state =
        if state.placeholder and state.current_message_id != nil do
          case update_current_message(%{state | placeholder: false}, @empty_message_text) do
            {:ok, updated} -> updated
            {:error, _} -> state
          end
        else
          state
        end

      {:ok, %{state | completed: true, pending_buffer: ""}}
    end
  end

  @spec fail(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def fail(%__MODULE__{} = state, message) when is_binary(message) do
    message = String.trim(message)

    cond do
      message == "" ->
        {:ok, %{state | completed: true}}

      state.current_message_id == nil ->
        case send_new_message(state, "Error: " <> message) do
          {:ok, state} -> {:ok, %{state | completed: true}}
          error -> error
        end

      state.placeholder ->
        # Replace placeholder with error
        case update_current_message(
               %{state | placeholder: false, status_text: nil},
               "Error: " <> message
             ) do
          {:ok, state} -> {:ok, %{state | completed: true}}
          error -> error
        end

      true ->
        text = state.active_text <> "\n\nError: " <> message

        case update_current_message(%{state | status_text: nil}, text) do
          {:ok, state} -> {:ok, %{state | completed: true}}
          error -> error
        end
    end
  end

  # ── consume: split by <newmsg/> and process each segment ──────────────

  defp consume(state, ""), do: {:ok, state}

  defp consume(state, data) do
    case String.split(data, @new_message_token, parts: 2) do
      [single] ->
        append_text(state, single)

      [before, after_text] ->
        with {:ok, state} <- append_text(state, String.trim(before)),
             {:ok, state} <- rotate_message(state) do
          consume(state, String.trim(after_text))
        end
    end
  end

  # ── split_processable: hold back incomplete <newmsg/> at chunk boundary ─

  defp split_processable(""), do: {"", ""}

  defp split_processable(data) do
    data_len = byte_size(data)
    tail_start = max(data_len - @newmsg_holdback_bytes, 0)
    tail = binary_part(data, tail_start, data_len - tail_start)
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
      if String.ends_with?(tail, prefix), do: prefix
    end)
  end

  # ── message lifecycle ──────────────────────────────────────────────────

  defp append_text(state, ""), do: {:ok, state}

  defp append_text(%__MODULE__{current_message_id: nil} = state, text) do
    text = String.trim_leading(text, "\n")

    if text == "" do
      {:ok, state}
    else
      send_new_message(state, text)
    end
  end

  defp append_text(%__MODULE__{placeholder: true} = state, text) do
    # First real text replaces the "Thinking..." placeholder
    text = String.trim_leading(text, "\n")

    if text == "" do
      {:ok, state}
    else
      update_current_message(%{state | placeholder: false, status_text: nil}, text)
    end
  end

  defp append_text(%__MODULE__{} = state, text) do
    state = %{state | status_text: nil}
    next_text = state.active_text <> text

    if String.length(next_text) > @max_message_length do
      with {:ok, state} <- rotate_message(state) do
        send_new_message(state, text)
      end
    else
      update_current_message(state, next_text)
    end
  end

  defp rotate_message(%__MODULE__{} = state) do
    {:ok,
     %{
       state
       | current_message_id: nil,
         active_text: "",
         status_text: nil,
         placeholder: false
     }}
  end

  defp send_new_message(%__MODULE__{} = state, text) do
    case Discord.deliver_message(state.instance_id, state.chat_id, text, state.metadata) do
      {:ok, message_id} ->
        {:ok,
         %{
           state
           | current_message_id: message_id,
             active_text: text,
             status_text: nil,
             placeholder: false
         }}

      {:error, reason} ->
        Logger.warning("[DiscordStream] send_new_message failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp update_current_message(%__MODULE__{current_message_id: nil} = state, text) do
    send_new_message(state, text)
  end

  defp update_current_message(%__MODULE__{} = state, text) do
    patch_current_message(state, %{state | active_text: text})
  end

  defp update_status_text(%__MODULE__{} = state, status_text) when is_binary(status_text) do
    patch_current_message(state, %{state | status_text: status_text})
  end

  defp patch_current_message(
         %__MODULE__{current_message_id: message_id} = previous,
         %__MODULE__{} = next
       )
       when is_binary(message_id) do
    previous_content = render_current_message(previous)
    next_content = render_current_message(next)

    if next_content == previous_content do
      {:ok, next}
    else
      case Discord.update_message(
             next.instance_id,
             next.chat_id,
             next.current_message_id,
             next_content,
             next.metadata
           ) do
        :ok ->
          {:ok, next}

        {:error, reason} ->
          Logger.warning("[DiscordStream] update_message failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp patch_current_message(%__MODULE__{}, %__MODULE__{} = next), do: {:ok, next}

  defp render_current_message(%__MODULE__{active_text: text, status_text: status})
       when is_binary(status) and status != "" do
    text = text || ""
    content = text <> "\n\n" <> status

    if String.length(content) <= @max_message_length do
      content
    else
      text
    end
  end

  defp render_current_message(%__MODULE__{active_text: text}), do: text || ""

  defp elapsed_seconds(%__MODULE__{started_at: started_at}) when is_integer(started_at) do
    max(System.monotonic_time(:second) - started_at, 0)
  end

  defp elapsed_seconds(%__MODULE__{}), do: 0
end
