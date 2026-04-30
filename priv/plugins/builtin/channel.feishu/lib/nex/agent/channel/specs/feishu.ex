defmodule Nex.Agent.Interface.Channel.Specs.Feishu do
  @moduledoc false

  @behaviour Nex.Agent.Interface.Channel.Spec
  require Logger

  alias Nex.Agent.Channel.Feishu.StreamConverter
  alias Nex.Agent.Channel.Feishu.StreamState
  alias Nex.Agent.Interface.Outbound.Action, as: OutboundAction

  @stream_flush_ms 500
  @impl true
  def type, do: "feishu"

  @impl true
  def gateway_module, do: Nex.Agent.Channel.Feishu

  @impl true
  def apply_defaults(instance) when is_map(instance) do
    instance
    |> Map.put("type", type())
    |> Map.put_new("streaming", true)
  end

  @impl true
  def validate_instance(instance, opts) when is_map(instance) do
    instance_id = Keyword.get(opts, :instance_id)

    diagnostics =
      if Map.get(instance, "enabled", false) == true do
        [
          required_diagnostic(instance, "app_id", instance_id),
          required_diagnostic(instance, "app_secret", instance_id)
        ]
        |> Enum.reject(&is_nil/1)
      else
        []
      end

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  @impl true
  def runtime(instance) when is_map(instance) do
    %{
      "type" => type(),
      "streaming" => Map.get(instance, "streaming", true) == true
    }
  end

  @impl true
  def format_prompt(runtime, _opts) when is_map(runtime) do
    streaming = if Map.get(runtime, "streaming", true) == true, do: "streaming", else: "single"

    """
    ## Feishu Output Contract

    - Current channel IR: Feishu markdown-like text IR.
    - Delivery mode: #{streaming}.
    - Feishu IR supports headings, lists, quotes, fenced code blocks, tables, and `<newmsg/>`.
    - `<newmsg/>` splits your reply into separate messages wherever it appears.
    - Keep normal replies as plain markdown-like text; do not emit Feishu JSON unless a tool explicitly asks for a native payload.
    """
    |> String.trim()
  end

  @impl true
  def im_profile, do: Nex.Agent.Interface.IMIR.Profiles.Feishu.profile()

  @impl true
  def renderer, do: Nex.Agent.Interface.IMIR.Renderers.Feishu

  @impl true
  def config_contract do
    %{
      "type" => type(),
      "label" => "Feishu",
      "ui" => %{
        "summary" => "Feishu/Lark bot websocket channel.",
        "requires" => ["app_id", "app_secret or env var", "allow_from for access control"]
      },
      "fields" => [
        "type",
        "enabled",
        "streaming",
        "app_id",
        "app_secret",
        "encrypt_key",
        "verification_token",
        "allow_from"
      ],
      "secret_fields" => ["app_secret", "encrypt_key", "verification_token"],
      "required_when_enabled" => ["app_id", "app_secret"],
      "defaults" => %{"streaming" => true},
      "options" => %{}
    }
  end

  @impl true
  def start_stream(instance_id, chat_id, metadata, opts)
      when is_binary(instance_id) and is_binary(chat_id) and is_map(metadata) do
    trace_id = "feishu-stream-#{System.unique_integer([:positive])}"
    started_at_ms = System.monotonic_time(:millisecond)

    metadata =
      metadata
      |> Map.put("_feishu_stream_trace_id", trace_id)
      |> Map.put("_feishu_stream_started_at_ms", started_at_ms)

    with {:ok, converter} <- StreamConverter.start(instance_id, chat_id, metadata) do
      feishu_stream_trace(
        trace_id,
        started_at_ms,
        "stream_started chat_id=#{chat_id} key=#{inspect(Keyword.get(opts, :key))}"
      )

      {:ok,
       %StreamState{
         converter: converter,
         trace_id: trace_id,
         started_at_ms: started_at_ms
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
      %{stream_state | pending_text: pending_text <> chunk}
      |> schedule_flush(opts)

    feishu_stream_trace(
      updated,
      "chunk bytes=#{byte_size(chunk)} pending_bytes=#{byte_size(updated.pending_text)} preview=#{inspect(String.slice(chunk, 0, 80))}"
    )

    {:ok, updated}
  end

  def handle_stream_event(%StreamState{} = stream_state, :finish, _opts) do
    feishu_stream_trace(
      stream_state,
      "finish_event pending_bytes=#{byte_size(stream_state.pending_text)}"
    )

    flush_stream(cancel_flush(stream_state))
  end

  def handle_stream_event(%StreamState{} = stream_state, {:approval_request, payload}, opts)
      when is_map(payload) do
    handle_action_event(stream_state, payload, opts)
  end

  def handle_stream_event(%StreamState{} = stream_state, {:action, payload}, opts)
      when is_map(payload) do
    handle_action_event(stream_state, payload, opts)
  end

  def handle_stream_event(%StreamState{} = stream_state, {:error, message}, _opts) do
    feishu_stream_trace(
      stream_state,
      "error_event pending_bytes=#{byte_size(stream_state.pending_text)} message=#{inspect(message)}"
    )

    with {:ok, %StreamState{converter: converter} = stream_state} <-
           flush_stream(cancel_flush(stream_state)),
         {:ok, updated_converter} <- StreamConverter.fail(converter, message) do
      {:ok, %{stream_state | converter: updated_converter}}
    end
  end

  def handle_stream_event(%StreamState{} = stream_state, _event, _opts), do: {:ok, stream_state}

  defp handle_action_event(%StreamState{} = stream_state, payload, opts) do
    fallback = OutboundAction.fallback_content(payload)

    if fallback == "" do
      {:ok, stream_state}
    else
      stream_state
      |> cancel_flush()
      |> flush_stream()
      |> case do
        {:ok, flushed} ->
          handle_stream_event(flushed, {:text, "\n" <> fallback <> "\n"}, opts)

        error ->
          error
      end
    end
  end

  @impl true
  def handle_stream_timer(%StreamState{} = stream_state, :flush, _opts) do
    flush_stream(stream_state)
  end

  def handle_stream_timer(%StreamState{} = stream_state, _timer, _opts), do: {:ok, stream_state}

  @impl true
  def finalize_stream(%StreamState{} = stream_state, result, _opts) do
    stream_state = cancel_flush(stream_state)

    with {:ok, %StreamState{converter: converter}} <- flush_stream(stream_state) do
      finalize_fun =
        case result do
          {:ok, _value} -> &StreamConverter.finish/1
          {:error, message, _reason} -> &StreamConverter.fail(&1, message)
          {:error, message} -> &StreamConverter.fail(&1, format_reason(message))
        end

      case finalize_fun.(converter) do
        {:ok, _updated} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def cancel_stream(%StreamState{} = stream_state) do
    cancel_flush(stream_state)
    :ok
  end

  defp required_diagnostic(instance, field, instance_id) do
    if present?(Map.get(instance, field)) do
      nil
    else
      %{
        code: :missing_required_channel_field,
        field: field,
        instance_id: instance_id,
        type: type(),
        message: "enabled feishu channel requires #{field}"
      }
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp schedule_flush(%StreamState{flush_timer_ref: nil} = stream_state, opts) do
    parent = Keyword.get(opts, :parent, self())
    key = Keyword.get(opts, :key)
    ref = Process.send_after(parent, {:channel_stream_timer, key, :flush}, @stream_flush_ms)

    feishu_stream_trace(
      stream_state,
      "schedule_flush delay_ms=#{@stream_flush_ms} pending_bytes=#{byte_size(stream_state.pending_text)}"
    )

    %{stream_state | flush_timer_ref: ref}
  end

  defp schedule_flush(stream_state, _opts), do: stream_state

  defp cancel_flush(%StreamState{flush_timer_ref: nil} = stream_state), do: stream_state

  defp cancel_flush(%StreamState{flush_timer_ref: ref} = stream_state) do
    Process.cancel_timer(ref)

    feishu_stream_trace(
      stream_state,
      "cancel_flush pending_bytes=#{byte_size(stream_state.pending_text)}"
    )

    %{stream_state | flush_timer_ref: nil}
  end

  defp flush_stream(%StreamState{pending_text: ""} = stream_state) do
    feishu_stream_trace(stream_state, "flush_skip pending_empty=true")
    {:ok, %{stream_state | flush_timer_ref: nil}}
  end

  defp flush_stream(%StreamState{converter: converter, pending_text: pending_text} = stream_state) do
    feishu_stream_trace(
      stream_state,
      "flush_start pending_bytes=#{byte_size(pending_text)} preview=#{inspect(String.slice(pending_text, 0, 120))}"
    )

    case StreamConverter.push_text(converter, pending_text) do
      {:ok, updated_converter} ->
        feishu_stream_trace(
          stream_state,
          "flush_done active_card_id=#{inspect(updated_converter.active_card_id)} active_len=#{byte_size(updated_converter.active_text)}"
        )

        {:ok,
         %{stream_state | converter: updated_converter, pending_text: "", flush_timer_ref: nil}}

      {:error, reason} ->
        feishu_stream_trace(stream_state, "flush_error reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp feishu_stream_trace(%StreamState{} = stream_state, message) do
    feishu_stream_trace(stream_state.trace_id, stream_state.started_at_ms, message)
  end

  defp feishu_stream_trace(trace_id, started_at_ms, message) do
    elapsed_ms =
      case started_at_ms do
        value when is_integer(value) -> System.monotonic_time(:millisecond) - value
        _ -> 0
      end

    Logger.info("[FeishuStream][#{trace_id}][+#{elapsed_ms}ms] #{message}")
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
