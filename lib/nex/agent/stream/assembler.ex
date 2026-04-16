defmodule Nex.Agent.Stream.Assembler do
  @moduledoc false

  alias Nex.Agent.Stream.Event

  @type mode :: :conversation | :consolidation

  @type t :: %__MODULE__{
          mode: mode(),
          run_id: String.t(),
          sink: (Event.t() -> term()) | nil,
          suppress_output?: boolean(),
          content_parts: [String.t()],
          reasoning_parts: [String.t()],
          tool_calls: [map()],
          finish_reason: String.t() | nil,
          usage: map() | nil,
          model: String.t() | nil,
          error: term() | nil,
          message_started?: boolean(),
          seq: non_neg_integer()
        }

  defstruct [
    :mode,
    :run_id,
    :sink,
    suppress_output?: false,
    content_parts: [],
    reasoning_parts: [],
    tool_calls: [],
    finish_reason: nil,
    usage: nil,
    model: nil,
    error: nil,
    message_started?: false,
    seq: 0
  ]

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      mode: Keyword.get(opts, :mode, :conversation),
      run_id: Keyword.get(opts, :run_id, "run_unknown"),
      sink: Keyword.get(opts, :sink),
      suppress_output?: Keyword.get(opts, :suppress_output?, false)
    }
  end

  @spec suppress_output(t(), boolean()) :: t()
  def suppress_output(%__MODULE__{} = assembler, suppress?) when is_boolean(suppress?) do
    %{assembler | suppress_output?: suppress?}
  end

  @spec prepare_next_response(t()) :: t()
  def prepare_next_response(%__MODULE__{} = assembler) do
    %{
      assembler
      | content_parts: [],
        reasoning_parts: [],
        tool_calls: [],
        finish_reason: nil,
        usage: nil,
        model: nil,
        error: nil
    }
  end

  @spec drain_stream((function() -> term()), t(), atom()) :: {:ok, t()} | {:error, term()}
  def drain_stream(stream_fun, %__MODULE__{} = assembler, tag)
      when is_function(stream_fun, 1) and is_atom(tag) do
    stream_ref = make_ref()
    caller = self()

    callback = fn event ->
      send(caller, {tag, stream_ref, event})
    end

    case stream_fun.(callback) do
      :ok ->
        {:ok, drain_events(tag, stream_ref, assembler)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec finalize(t()) :: {t(), map()}
  def finalize(%__MODULE__{} = assembler) do
    assembler = emit_message_end(assembler)

    {assembler,
     %{
       content: assembled_content(assembler),
       reasoning_content: assembled_reasoning_content(assembler),
       tool_calls: assembler.tool_calls,
       finish_reason: assembler.finish_reason,
       model: assembler.model,
       usage: assembler.usage,
       streamed_text: assembler.content_parts != [],
       error: assembler.error
     }}
  end

  @spec emit_text_delta(t(), String.t() | nil) :: t()
  def emit_text_delta(%__MODULE__{} = assembler, text) when is_binary(text) do
    if text != "" do
      assembler
      |> maybe_start_message()
      |> emit_event(:text_delta, content: text)
    else
      assembler
    end
  end

  def emit_text_delta(%__MODULE__{} = assembler, _text), do: assembler

  @spec emit_text_commit(t(), term()) :: t()
  def emit_text_commit(%__MODULE__{} = assembler, content) do
    text =
      content
      |> render_text()
      |> String.replace(~r/<think>.*?<\/think>/s, "")
      |> String.trim()

    if text != "" do
      emit_event(assembler, :text_commit, content: text)
    else
      assembler
    end
  end

  @spec emit_tool_call_start_events(t(), [map()]) :: t()
  def emit_tool_call_start_events(%__MODULE__{} = assembler, tool_call_dicts)
      when is_list(tool_call_dicts) do
    Enum.reduce(tool_call_dicts, assembler, fn tc, acc ->
      emit_event(acc, :tool_call_start,
        name: get_in(tc, ["function", "name"]),
        tool_call_id: Map.get(tc, "id"),
        data: %{"arguments" => get_in(tc, ["function", "arguments"])}
      )
    end)
  end

  @spec emit_tool_result_events(t(), list()) :: t()
  def emit_tool_result_events(%__MODULE__{} = assembler, results) when is_list(results) do
    Enum.reduce(results, assembler, fn {tool_call_id, tool_name, result, _args}, acc ->
      acc
      |> emit_event(:tool_call_result,
        name: tool_name,
        tool_call_id: tool_call_id,
        content: render_text(result),
        data: %{}
      )
      |> emit_event(:tool_call_end,
        name: tool_name,
        tool_call_id: tool_call_id,
        data: %{}
      )
    end)
  end

  @spec emit_error(t(), term()) :: t()
  def emit_error(%__MODULE__{} = assembler, reason) do
    emit_event(assembler, :error,
      content: format_reason(reason),
      data: %{reason: inspect(reason)}
    )
  end

  @spec emit_message_end(t()) :: t()
  def emit_message_end(%__MODULE__{} = assembler) do
    if assembler.mode == :conversation and not assembler.suppress_output? do
      emit_event(assembler, :message_end, content: assembled_content(assembler), data: %{})
    else
      assembler
    end
  end

  defp drain_events(tag, stream_ref, assembler) do
    receive do
      {^tag, ^stream_ref, {:delta, text}} ->
        text = to_string(text)

        assembler =
          assembler
          |> append_content(text)
          |> maybe_emit_stream_delta(text)

        drain_events(tag, stream_ref, assembler)

      {^tag, ^stream_ref, {:thinking, text}} ->
        drain_events(tag, stream_ref, append_reasoning(assembler, to_string(text)))

      {^tag, ^stream_ref, {:tool_calls, tool_calls}} ->
        drain_events(tag, stream_ref, %{assembler | tool_calls: tool_calls})

      {^tag, ^stream_ref, {:done, metadata}} ->
        %{
          assembler
          | finish_reason: metadata[:finish_reason],
            usage: metadata[:usage],
            model: metadata[:model]
        }

      {^tag, ^stream_ref, {:error, error}} ->
        %{assembler | error: error}
    after
      1_000 ->
        assembler
    end
  end

  defp maybe_emit_stream_delta(%__MODULE__{mode: :conversation, suppress_output?: false} = assembler, text) do
    assembler
    |> maybe_start_message()
    |> emit_event(:text_delta, content: text)
  end

  defp maybe_emit_stream_delta(%__MODULE__{} = assembler, _text), do: assembler

  defp maybe_start_message(%__MODULE__{message_started?: true} = assembler), do: assembler

  defp maybe_start_message(%__MODULE__{} = assembler) do
    emit_event(assembler, :message_start, data: %{})
  end

  defp append_content(%__MODULE__{} = assembler, text) when is_binary(text) do
    %{assembler | content_parts: [text | assembler.content_parts]}
  end

  defp append_reasoning(%__MODULE__{} = assembler, text) when is_binary(text) do
    %{assembler | reasoning_parts: [text | assembler.reasoning_parts]}
  end

  defp emit_event(%__MODULE__{sink: sink} = assembler, type, attrs)
       when is_function(sink, 1) do
    seq = assembler.seq + 1

    event = %Event{
      seq: seq,
      run_id: assembler.run_id,
      type: type,
      content: Keyword.get(attrs, :content),
      name: Keyword.get(attrs, :name),
      tool_call_id: Keyword.get(attrs, :tool_call_id),
      data: Keyword.get(attrs, :data, %{})
    }

    sink.(event)

    %{
      assembler
      | seq: seq,
        message_started?: assembler.message_started? or type == :message_start
    }
  end

  defp emit_event(%__MODULE__{} = assembler, _type, _attrs), do: assembler

  defp assembled_content(%__MODULE__{mode: :consolidation, content_parts: parts}) do
    parts
    |> Enum.reverse()
    |> Enum.join()
    |> String.trim()
  end

  defp assembled_content(%__MODULE__{content_parts: parts}) do
    parts
    |> Enum.reverse()
    |> Enum.join()
  end

  defp assembled_reasoning_content(%__MODULE__{reasoning_parts: parts}) do
    parts
    |> Enum.reverse()
    |> Enum.join()
  end

  defp render_text(nil), do: ""
  defp render_text(text) when is_binary(text), do: text
  defp render_text(text), do: inspect(text, printable_limit: 500, limit: 50)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
