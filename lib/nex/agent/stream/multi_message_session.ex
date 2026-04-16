defmodule Nex.Agent.Stream.MultiMessageSession do
  @moduledoc false

  @behaviour Nex.Agent.Stream.Session

  alias Nex.Agent.Stream.{Event, Result, Session}
  alias Nex.Agent.Stream.TransportActions

  @flush_chars 48

  defstruct [
    :key,
    :channel,
    :chat_id,
    metadata: %{},
    visible_text: "",
    flushed_length: 0,
    user_visible: false,
    completed: false
  ]

  @type t :: %__MODULE__{
          key: term(),
          channel: String.t(),
          chat_id: String.t(),
          metadata: map(),
          visible_text: String.t(),
          flushed_length: non_neg_integer(),
          user_visible: boolean(),
          completed: boolean()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      key: Keyword.fetch!(opts, :key),
      channel: Keyword.fetch!(opts, :channel),
      chat_id: Keyword.fetch!(opts, :chat_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @impl Session
  @spec open_session(term(), String.t(), String.t(), map()) :: {:ok, t()} | :error
  def open_session(key, channel, chat_id, metadata) when is_binary(channel) and is_map(metadata) do
    {:ok, new(key: key, channel: channel, chat_id: chat_id, metadata: metadata)}
  end

  def open_session(_key, _channel, _chat_id, _metadata), do: :error

  @impl Session
  def capability(%__MODULE__{}), do: :multi_message

  @impl Session
  def handle_event(%__MODULE__{} = session, %Event{type: :message_start}), do: {session, []}

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
    text = fallback_text(content, "Error")
    updated = %{session | completed: true, user_visible: true}
    {updated, [publish_action(updated, text)]}
  end

  def handle_event(%__MODULE__{} = session, _event), do: {session, []}

  @impl Session
  def finalize_success(%__MODULE__{} = session, %Result{} = result) do
    cond do
      session.completed ->
        {session, [], true}

      Result.message_sent?(result) ->
        {%{session | completed: true}, [], true}

      is_binary(result.final_content) and String.trim(result.final_content) != "" ->
        publish_final(session, result.final_content)

      session.user_visible ->
        {updated, actions} = maybe_flush_text(session, true)
        {%{updated | completed: true}, actions, true}

      true ->
        {%{session | completed: true}, [], true}
    end
  end

  @impl Session
  def finalize_error(%__MODULE__{} = session, %Result{} = result) do
    if session.completed do
      {session, [], true}
    else
      message =
        cond do
          is_binary(result.final_content) and String.trim(result.final_content) != "" ->
            result.final_content

          true ->
            to_string(result.error || "Error")
        end

      text = fallback_text(message, "Error")
      updated = %{session | completed: true, user_visible: true}
      {updated, [publish_action(updated, text)], true}
    end
  end

  @impl Session
  def run_actions(actions), do: TransportActions.run(actions)

  defp maybe_flush_text(%__MODULE__{} = session, force?) do
    pending_text = pending_text(session)

    should_flush? =
      force? or
        (pending_text != "" and
           (String.length(pending_text) >= @flush_chars or
              String.ends_with?(pending_text, [".", "!", "?", "。", "！", "？", "\n"])))

    if should_flush? and pending_text != "" do
      updated = %{session | flushed_length: String.length(session.visible_text)}
      {updated, [publish_action(updated, pending_text)]}
    else
      {session, []}
    end
  end

  defp pending_text(%__MODULE__{} = session) do
    session.visible_text
    |> String.slice(session.flushed_length, String.length(session.visible_text))
    |> to_string()
  end

  defp publish_final(%__MODULE__{} = session, content) do
    {updated, actions} =
      maybe_flush_text(%{session | visible_text: content, user_visible: true}, true)

    {%{updated | completed: true}, actions, true}
  end

  defp publish_action(%__MODULE__{} = session, content) do
    {:publish, session.channel, session.chat_id, content, session.metadata}
  end

  defp fallback_text(content, default) when is_binary(content) do
    if String.trim(content) == "", do: default, else: content
  end

  defp fallback_text(_content, default), do: default
end
