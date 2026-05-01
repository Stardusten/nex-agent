defmodule Nex.Agent.Turn.ContextWindow do
  @moduledoc false

  alias Nex.Agent.{Turn.ContextBuilder, Conversation.Session}
  alias Nex.Agent.Turn.LLM.ResponseInfo
  alias Nex.Agent.Turn.ContextWindow.{Estimator, TokenUsage}

  @projection_key "context_window_projection"
  @ledger_key "context_window_v2"
  @default_safety_margin_tokens 4_096
  @loop_recent_messages 12
  @native_strategies MapSet.new([
                       "server_side",
                       "server_side_then_recent",
                       "provider_native",
                       "provider_native_then_recent",
                       "native",
                       "native_compaction"
                     ])

  @type spec :: %{
          context_window: pos_integer() | nil,
          auto_compact_token_limit: pos_integer() | nil,
          context_strategy: String.t() | nil,
          native_compaction?: boolean()
        }

  @spec spec(keyword()) :: spec()
  def spec(opts) do
    runtime = Keyword.get(opts, :model_runtime) || %{}
    provider = Keyword.get(opts, :provider)
    provider_options = Keyword.get(opts, :provider_options, [])

    strategy =
      normalize_strategy(
        runtime_value(runtime, :context_strategy) || opt(provider_options, :context_strategy)
      )

    %{
      context_window:
        positive_integer(
          runtime_value(runtime, :context_window) || opt(provider_options, :context_window)
        ),
      auto_compact_token_limit:
        positive_integer(
          runtime_value(runtime, :auto_compact_token_limit) ||
            opt(provider_options, :auto_compact_token_limit)
        ),
      context_strategy: strategy,
      native_compaction?: native_compaction?(provider, strategy)
    }
  end

  @spec select_history(
          Session.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          list() | nil,
          keyword(),
          keyword()
        ) :: {[map()], map()}
  def select_history(%Session{} = session, prompt, channel, chat_id, media, build_opts, opts) do
    cond do
      Keyword.has_key?(opts, :history_limit) ->
        history = Session.get_history(session, Keyword.get(opts, :history_limit, 0))
        {history, %{mode: "message_limit", history_limit: Keyword.get(opts, :history_limit, 0)}}

      true ->
        do_select_history(session, prompt, channel, chat_id, media, build_opts, opts)
    end
  end

  @spec prepare_provider_options(keyword(), Session.t()) :: keyword()
  def prepare_provider_options(opts, %Session{} = session) do
    spec = spec(opts)
    provider_options = Keyword.get(opts, :provider_options, [])

    provider_options
    |> maybe_put_native_context_management(spec)
    |> maybe_put_native_compaction_items(spec, session)
  end

  @spec store_response_compaction(Session.t(), map(), keyword()) :: Session.t()
  def store_response_compaction(%Session{} = session, response, opts) when is_map(response) do
    items = response_compaction_items(response)
    spec = spec(opts)

    if items == [] or not spec.native_compaction? do
      session
    else
      provider = Keyword.get(opts, :provider)
      model = Keyword.get(opts, :model)
      cutoff = Keyword.get(opts, :compacted_until, max(length(session.messages) - 1, 0))

      projection = %{
        "provider" => provider && to_string(provider),
        "model" => model && to_string(model),
        "context_strategy" => spec.context_strategy,
        "kind" => "native_compaction",
        "compacted_until" => cutoff,
        "items" => items,
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      %{session | metadata: Map.put(session.metadata || %{}, @projection_key, projection)}
    end
  end

  @spec compact_loop_messages([map()], map(), keyword()) :: {[map()], keyword()}
  def compact_loop_messages(messages, response, opts)
      when is_list(messages) and is_map(response) do
    items = response_compaction_items(response)
    spec = spec(opts)

    if items == [] or not spec.native_compaction? do
      {messages, opts}
    else
      provider_options =
        opts
        |> Keyword.get(:provider_options, [])
        |> Keyword.put(:context_compaction_items, items)

      {keep_system_and_recent(messages, @loop_recent_messages),
       Keyword.put(opts, :provider_options, provider_options)}
    end
  end

  @spec estimate_tokens(term()) :: non_neg_integer()
  def estimate_tokens(value), do: Estimator.estimate(value)

  @spec estimate_breakdown(term()) :: map()
  def estimate_breakdown(value), do: Estimator.estimate_breakdown(value)

  @spec truncate_tool_result(term(), keyword()) :: {String.t(), map()}
  def truncate_tool_result(result, opts) do
    text = if is_binary(result), do: result, else: inspect(result)
    limit = tool_output_token_limit(opts)
    {visible, attrs} = Estimator.truncate_text(text, limit)

    attrs =
      attrs
      |> stringify_map()
      |> Map.merge(%{
        "original_bytes" => byte_size(text),
        "visible_bytes" => byte_size(visible),
        "token_limit_source" => tool_output_token_limit_source(opts)
      })

    {visible, attrs}
  end

  @spec record_response(Session.t(), map(), keyword(), keyword()) :: {Session.t(), map()}
  def record_response(session, response, opts, meta \\ [])

  def record_response(%Session{} = session, response, opts, meta) when is_map(response) do
    usage = normalized_usage(response)
    finish_reason = ResponseInfo.finish_reason(response)
    incomplete_reason = ResponseInfo.incomplete_reason(response)
    status = Keyword.get(meta, :status, ResponseInfo.status(response))
    iteration = Keyword.get(meta, :iteration)
    projection = Keyword.get(meta, :projection, last_projection(session))
    model_runtime = Keyword.get(opts, :model_runtime) || %{}

    ledger =
      session.metadata
      |> ensure_metadata()
      |> Map.get(@ledger_key, %{})
      |> ensure_metadata()
      |> Map.merge(%{
        "version" => 1,
        "provider" => opts |> Keyword.get(:provider) |> stringify(),
        "model" => opts |> Keyword.get(:model) |> stringify(),
        "model_key" => runtime_value(model_runtime, :model_key) |> stringify(),
        "history_version" => length(session.messages),
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
      |> maybe_put_successful_anchor(session, response, usage, finish_reason)
      |> maybe_put_incomplete(
        response,
        usage,
        finish_reason,
        incomplete_reason,
        status,
        iteration
      )
      |> maybe_put_last_projection(projection)

    metadata =
      session.metadata
      |> ensure_metadata()
      |> Map.put(@ledger_key, ledger)

    attrs = ledger_attrs(ledger, usage, finish_reason, incomplete_reason)

    {%{session | metadata: metadata, updated_at: DateTime.utc_now()}, attrs}
  end

  def record_response(%Session{} = session, _response, _opts, _meta), do: {session, %{}}

  defp do_select_history(session, prompt, channel, chat_id, media, build_opts, opts) do
    spec = spec(opts)
    default_limit = Keyword.get(opts, :default_history_limit, 50)

    if is_integer(spec.context_window) and spec.context_window > 0 do
      base_messages =
        ContextBuilder.build_messages([], prompt, channel, chat_id, media, build_opts)

      base_breakdown = estimate_breakdown(base_messages)
      base_tokens = base_breakdown.total
      budget = max(input_budget(spec, opts) - base_tokens, 0)
      messages = projection_messages(session, spec)
      history = history_within_budget(messages, budget)
      history_breakdown = estimate_breakdown(history)

      {history,
       %{
         mode: "token_budget",
         context_window: spec.context_window,
         auto_compact_token_limit: spec.auto_compact_token_limit,
         context_strategy: spec.context_strategy,
         native_compaction?: spec.native_compaction?,
         base_tokens_estimate: base_tokens,
         base_token_breakdown: stringify_map(base_breakdown),
         history_tokens_estimate: history_breakdown.total,
         history_token_breakdown: stringify_map(history_breakdown),
         history_budget_tokens_estimate: budget,
         history_message_count: length(history),
         usage_source: ledger_usage_source(session)
       }}
    else
      history = Session.get_history(session, default_limit)
      {history, %{mode: "message_limit", history_limit: default_limit}}
    end
  end

  defp input_budget(%{context_window: context_window}, opts) when is_integer(context_window) do
    output_budget =
      Keyword.get(opts, :max_tokens) ||
        opts |> Keyword.get(:provider_options, []) |> opt(:max_tokens) ||
        opts |> Keyword.get(:provider_options, []) |> opt(:max_output_tokens) ||
        4_096

    max(
      context_window - positive_integer(output_budget, 4_096) - @default_safety_margin_tokens,
      0
    )
  end

  defp input_budget(_spec, _opts), do: nil

  defp tool_output_token_limit(opts) do
    explicit =
      Keyword.get(opts, :tool_output_token_limit) ||
        opts |> Keyword.get(:provider_options, []) |> opt(:tool_output_token_limit) ||
        opts |> Keyword.get(:model_runtime, %{}) |> runtime_value(:tool_output_token_limit)

    spec = spec(opts)
    budget = input_budget(spec, opts)

    explicit
    |> positive_integer(nil)
    |> case do
      value when is_integer(value) and is_integer(budget) and budget > 0 ->
        min(value, max(budget, 1))

      value when is_integer(value) ->
        value

      _ ->
        default_tool_output_token_limit(budget)
    end
  end

  defp tool_output_token_limit_source(opts) do
    explicit =
      Keyword.get(opts, :tool_output_token_limit) ||
        opts |> Keyword.get(:provider_options, []) |> opt(:tool_output_token_limit) ||
        opts |> Keyword.get(:model_runtime, %{}) |> runtime_value(:tool_output_token_limit)

    if positive_integer(explicit, nil), do: "config", else: "context_budget"
  end

  defp default_tool_output_token_limit(budget) when is_integer(budget) and budget > 0 do
    cond do
      budget < 512 -> max(budget, 128)
      true -> budget |> div(8) |> clamp(512, 16_000)
    end
  end

  defp default_tool_output_token_limit(_budget), do: 2_000

  defp clamp(value, min_value, max_value) do
    value
    |> max(min_value)
    |> min(max_value)
  end

  defp projection_messages(%Session{} = session, %{native_compaction?: true}) do
    case native_projection(session) do
      %{"compacted_until" => cutoff} when is_integer(cutoff) and cutoff > 0 ->
        Enum.drop(session.messages, cutoff)

      _ ->
        session.messages
    end
  end

  defp projection_messages(%Session{} = session, _spec), do: session.messages

  defp history_within_budget(messages, budget) do
    session = %{Session.new("context-window") | messages: messages}
    history = Session.get_history(session, length(messages))

    history
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn message, {acc, used} ->
      cost = estimate_tokens(message)

      if used + cost <= budget or acc == [] do
        {:cont, {[message | acc], used + cost}}
      else
        {:halt, {acc, used}}
      end
    end)
    |> elem(0)
    |> repair_user_boundary()
  end

  defp repair_user_boundary([]), do: []

  defp repair_user_boundary(history) do
    case Enum.find_index(history, &(Map.get(&1, "role") == "user")) do
      nil -> history
      idx -> Enum.drop(history, idx)
    end
  end

  defp keep_system_and_recent(messages, recent_count) do
    {system, rest} = Enum.split_with(messages, &(Map.get(&1, "role") == "system"))
    system ++ Enum.take(rest, -recent_count)
  end

  defp maybe_put_native_context_management(provider_options, %{native_compaction?: true} = spec) do
    case spec.auto_compact_token_limit do
      limit when is_integer(limit) and limit > 0 ->
        Keyword.put(provider_options, :context_management, [
          %{"type" => "compaction", "compact_threshold" => limit}
        ])

      _ ->
        provider_options
    end
  end

  defp maybe_put_native_context_management(provider_options, _spec), do: provider_options

  defp maybe_put_native_compaction_items(provider_options, %{native_compaction?: true}, session) do
    case native_projection(session) do
      %{"items" => items} when is_list(items) and items != [] ->
        Keyword.put(provider_options, :context_compaction_items, items)

      _ ->
        provider_options
    end
  end

  defp maybe_put_native_compaction_items(provider_options, _spec, _session), do: provider_options

  defp native_projection(%Session{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @projection_key) do
      %{"kind" => "native_compaction"} = projection -> projection
      _ -> nil
    end
  end

  defp native_projection(_session), do: nil

  defp last_projection(%Session{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @ledger_key) do
      %{"last_projection" => projection} when is_map(projection) -> projection
      _ -> %{}
    end
  end

  defp last_projection(_session), do: %{}

  defp ledger_usage_source(%Session{metadata: metadata}) when is_map(metadata) do
    case get_in(metadata, [@ledger_key, "last_successful_anchor", "usage", "source"]) do
      source when is_binary(source) -> source
      _ -> "estimate"
    end
  end

  defp ledger_usage_source(_session), do: "estimate"

  defp response_compaction_items(response) do
    metadata = ResponseInfo.metadata(response)

    metadata
    |> Map.get(:context_compaction_items, Map.get(metadata, "context_compaction_items", []))
    |> normalize_items()
  end

  defp normalized_usage(response) do
    response
    |> ResponseInfo.usage()
    |> TokenUsage.normalize()
  end

  defp maybe_put_successful_anchor(ledger, _session, _response, nil, _finish_reason), do: ledger

  defp maybe_put_successful_anchor(
         ledger,
         session,
         response,
         %TokenUsage{} = usage,
         finish_reason
       ) do
    if successful_finish_reason?(finish_reason) and usage.source == :provider do
      Map.put(ledger, "last_successful_anchor", %{
        "message_index" => length(session.messages),
        "response_id" => response_id(response),
        "usage" => TokenUsage.to_summary(usage),
        "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    else
      ledger
    end
  end

  defp maybe_put_incomplete(ledger, _response, usage, finish_reason, reason, _status, iteration)
       when finish_reason in ["incomplete", :incomplete] do
    Map.put(ledger, "last_incomplete", %{
      "finish_reason" => "incomplete",
      "reason" => stringify(reason || "unknown"),
      "iteration" => iteration,
      "usage" => TokenUsage.to_summary(usage) || %{},
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp maybe_put_incomplete(ledger, _response, _usage, _finish_reason, _reason, status, iteration)
       when status in ["incomplete", :incomplete] do
    Map.put(ledger, "last_incomplete", %{
      "finish_reason" => "incomplete",
      "reason" => "unknown",
      "iteration" => iteration,
      "usage" => %{},
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp maybe_put_incomplete(
         ledger,
         _response,
         _usage,
         _finish_reason,
         _reason,
         _status,
         _iteration
       ),
       do: ledger

  defp maybe_put_last_projection(ledger, projection)
       when is_map(projection) and map_size(projection) > 0 do
    Map.put(ledger, "last_projection", projection)
  end

  defp maybe_put_last_projection(ledger, _projection), do: ledger

  defp successful_finish_reason?(nil), do: true
  defp successful_finish_reason?("stop"), do: true
  defp successful_finish_reason?(:stop), do: true
  defp successful_finish_reason?("tool_calls"), do: true
  defp successful_finish_reason?(:tool_calls), do: true
  defp successful_finish_reason?(_), do: false

  defp response_id(response) do
    metadata = ResponseInfo.metadata(response)

    Map.get(response, :response_id) ||
      Map.get(response, "response_id") ||
      Map.get(metadata, :response_id) ||
      Map.get(metadata, "response_id")
  end

  defp ledger_attrs(ledger, usage, finish_reason, incomplete_reason) do
    usage_summary = TokenUsage.to_summary(usage)

    %{
      "usage_available" => not is_nil(usage_summary),
      "usage_source" => get_in(usage_summary || %{}, ["source"]) || "estimate",
      "usage_missing_fields" => get_in(usage_summary || %{}, ["missing_fields"]) || [],
      "finish_reason" => stringify(finish_reason),
      "incomplete_reason" => stringify(incomplete_reason),
      "has_successful_anchor" => is_map(Map.get(ledger, "last_successful_anchor"))
    }
    |> maybe_put_attr("usage", usage_summary)
  end

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp normalize_items(items) when is_list(items) do
    items
    |> Enum.filter(&compaction_item?/1)
    |> Enum.map(&stringify_keys/1)
    |> uniq_items()
  end

  defp normalize_items(_items), do: []

  defp compaction_item?(%{"type" => "compaction"}), do: true
  defp compaction_item?(%{type: "compaction"}), do: true
  defp compaction_item?(%{type: :compaction}), do: true
  defp compaction_item?(_item), do: false

  defp uniq_items(items) do
    {_seen, uniq} =
      Enum.reduce(items, {MapSet.new(), []}, fn item, {seen, acc} ->
        id = Map.get(item, "id") || :erlang.phash2(item)

        if MapSet.member?(seen, id) do
          {seen, acc}
        else
          {MapSet.put(seen, id), [item | acc]}
        end
      end)

    Enum.reverse(uniq)
  end

  defp native_compaction?(provider, strategy) do
    provider in [:openai_codex, :openai_codex_custom] and
      MapSet.member?(@native_strategies, strategy)
  end

  defp normalize_strategy(nil), do: nil

  defp normalize_strategy(strategy) when is_atom(strategy) do
    strategy |> Atom.to_string() |> normalize_strategy()
  end

  defp normalize_strategy(strategy) when is_binary(strategy) do
    strategy
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_strategy(_strategy), do: nil

  defp runtime_value(runtime, key) when is_map(runtime) do
    Map.get(runtime, key) || Map.get(runtime, Atom.to_string(key))
  end

  defp runtime_value(_runtime, _key), do: nil

  defp opt(options, key, default \\ nil)
  defp opt(options, key, default) when is_list(options), do: Keyword.get(options, key, default)
  defp opt(options, key, default) when is_map(options), do: Map.get(options, key, default)
  defp opt(_options, _key, default), do: default

  defp positive_integer(value, default \\ nil)
  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp ensure_metadata(metadata) when is_map(metadata), do: metadata
  defp ensure_metadata(_metadata), do: %{}

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_map_value(value)} end)
  end

  defp stringify_map_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_map_value(value) when is_list(value), do: Enum.map(value, &stringify_map_value/1)
  defp stringify_map_value(value) when is_boolean(value), do: value
  defp stringify_map_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_map_value(value), do: value

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
