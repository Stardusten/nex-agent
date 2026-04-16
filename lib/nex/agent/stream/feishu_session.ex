defmodule Nex.Agent.Stream.FeishuSession do
  @moduledoc false

  @behaviour Nex.Agent.Stream.Session

  alias Nex.Agent.Channel.Feishu
  alias Nex.Agent.Stream.{Event, Result, Session}

  @min_update_interval_ms 120
  @flush_chars 24

  defstruct [
    :key,
    :chat_id,
    :card_message_id,
    visible_text: "",
    last_flushed_text: "",
    last_flush_at_ms: 0,
    tool_hints: [],
    user_visible: false,
    completed: false
  ]

  @type t :: %__MODULE__{
          key: term(),
          chat_id: String.t(),
          card_message_id: String.t(),
          visible_text: String.t(),
          last_flushed_text: String.t(),
          last_flush_at_ms: integer(),
          tool_hints: [String.t()],
          user_visible: boolean(),
          completed: boolean()
        }

  @type action :: {:update_card, String.t(), String.t()}

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      key: Keyword.fetch!(opts, :key),
      chat_id: Keyword.fetch!(opts, :chat_id),
      card_message_id: Keyword.fetch!(opts, :card_message_id)
    }
  end

  @impl Session
  @spec open_session(term(), String.t(), String.t(), map()) :: {:ok, t()} | :error
  def open_session(key, "feishu", chat_id, metadata) when is_map(metadata) do
    case Feishu.send_card(chat_id, "✨ Thinking...", metadata) do
      {:ok, message_id} when is_binary(message_id) and message_id != "" ->
        {:ok, new(key: key, chat_id: chat_id, card_message_id: message_id)}

      _ ->
        :error
    end
  end

  def open_session(_key, _channel, _chat_id, _metadata), do: :error

  @impl Session
  def capability(%__MODULE__{}), do: :edit_message

  @impl Session
  @spec handle_event(t(), Event.t()) :: {t(), [action()]}
  def handle_event(%__MODULE__{} = session, %Event{type: :message_start}) do
    maybe_render_progress(session)
  end

  def handle_event(%__MODULE__{} = session, %Event{type: :tool_call_start, name: name, data: data}) do
    args = Map.get(data, "arguments") || "..."
    hint = "#{name}(#{truncate_hint(args)})"
    session = %{session | tool_hints: session.tool_hints ++ [hint]}
    maybe_render_progress(session)
  end

  def handle_event(%__MODULE__{} = session, %Event{type: :text_delta, content: content})
      when is_binary(content) do
    session = %{session | visible_text: session.visible_text <> content, user_visible: true}
    maybe_flush_text(session, false)
  end

  def handle_event(%__MODULE__{} = session, %Event{type: :text_commit}) do
    maybe_flush_text(session, true)
  end

  def handle_event(%__MODULE__{} = session, %Event{type: :message_end}) do
    {session, actions} = maybe_flush_text(session, true)
    {%{session | completed: true}, actions}
  end

  def handle_event(%__MODULE__{} = session, %Event{type: :error, content: content}) do
    message = if is_binary(content) and String.trim(content) != "", do: content, else: "Error"

    session = %{
      session
      | visible_text: message,
        last_flushed_text: message,
        user_visible: true,
        completed: true
    }

    {session, [update_card_action(session, message)]}
  end

  def handle_event(%__MODULE__{} = session, _event), do: {session, []}

  @impl Session
  @spec finalize_success(t(), Result.t()) :: {t(), [action()], boolean()}
  def finalize_success(%__MODULE__{} = session, %Result{} = result) do
    cond do
      session.completed and session.user_visible ->
        {session, [], true}

      session.user_visible ->
        {session, actions} = maybe_flush_text(session, true)
        {%{session | completed: true}, actions, true}

      Result.message_sent?(result) ->
        text = "✅ Done"
        {%{session | completed: true}, [update_card_action(session, text)], true}

      is_binary(result.final_content) and String.trim(result.final_content) != "" ->
        text = String.trim(result.final_content)

        session = %{
          session
          | visible_text: text,
            last_flushed_text: text,
            user_visible: true,
            completed: true
        }

        {session, [update_card_action(session, text)], true}

      true ->
        text = completion_text(session)
        {%{session | completed: true}, [update_card_action(session, text)], true}
    end
  end

  @impl Session
  @spec finalize_error(t(), Result.t()) :: {t(), [action()], boolean()}
  def finalize_error(%__MODULE__{} = session, %Result{} = result) do
    message =
      cond do
        is_binary(result.final_content) and String.trim(result.final_content) != "" ->
          result.final_content

        true ->
          to_string(result.error || "Error")
      end

    text = if String.trim(message) == "", do: "Error", else: message

    handle_event(session, %Event{seq: 0, run_id: "error", type: :error, content: text})
    |> then(fn {updated, actions} -> {updated, actions, true} end)
  end

  @impl Session
  def run_actions(actions) do
    Enum.each(actions, fn
      {:update_card, message_id, text} ->
        Nex.Agent.Channel.Feishu.update_card(message_id, text)

      _ ->
        :ok
    end)
  end

  defp maybe_render_progress(%__MODULE__{user_visible: true} = session), do: {session, []}

  defp maybe_render_progress(%__MODULE__{} = session) do
    {session, [update_card_action(session, progress_text(session))]}
  end

  defp maybe_flush_text(%__MODULE__{} = session, force?) do
    visible_text = session.visible_text
    last_flushed_text = session.last_flushed_text
    now = System.monotonic_time(:millisecond)

    should_flush? =
      force? or
        (visible_text != last_flushed_text and
           (byte_size(visible_text) - byte_size(last_flushed_text) >= @flush_chars or
              now - session.last_flush_at_ms >= @min_update_interval_ms or
              String.ends_with?(visible_text, [".", "!", "?", "。", "！", "？", "\n"])))

    if visible_text != "" and should_flush? do
      updated = %{session | last_flushed_text: visible_text, last_flush_at_ms: now}
      {updated, [update_card_action(updated, visible_text)]}
    else
      {session, []}
    end
  end

  defp completion_text(%__MODULE__{tool_hints: []}), do: "✅ Done"

  defp completion_text(%__MODULE__{} = session),
    do: Enum.map_join(session.tool_hints, "\n", &"⚙️ #{&1}") <> "\n✅ Done"

  defp progress_text(%__MODULE__{tool_hints: []}), do: "💡 Thinking..."

  defp progress_text(%__MODULE__{} = session) do
    Enum.map_join(session.tool_hints, "\n", &"⚙️ #{&1}") <> "\n💡 Thinking..."
  end

  defp update_card_action(%__MODULE__{card_message_id: message_id}, text),
    do: {:update_card, message_id, text}

  defp truncate_hint(text) when is_binary(text) and byte_size(text) > 120 do
    String.slice(text, 0, 117) <> "..."
  end

  defp truncate_hint(text), do: to_string(text)
end
