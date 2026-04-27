defmodule Nex.Agent.ContextWindow do
  @moduledoc false

  alias Nex.Agent.{ContextBuilder, Session}

  @projection_key "context_window_projection"
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
  def estimate_tokens(value) do
    value
    |> text_size()
    |> Kernel.+(3)
    |> div(4)
  end

  defp do_select_history(session, prompt, channel, chat_id, media, build_opts, opts) do
    spec = spec(opts)
    default_limit = Keyword.get(opts, :default_history_limit, 50)

    if is_integer(spec.context_window) and spec.context_window > 0 do
      base_messages =
        ContextBuilder.build_messages([], prompt, channel, chat_id, media, build_opts)

      base_tokens = estimate_tokens(base_messages)
      budget = max(input_budget(spec, opts) - base_tokens, 0)
      messages = projection_messages(session, spec)
      history = history_within_budget(messages, budget)

      {history,
       %{
         mode: "token_budget",
         context_window: spec.context_window,
         auto_compact_token_limit: spec.auto_compact_token_limit,
         context_strategy: spec.context_strategy,
         native_compaction?: spec.native_compaction?,
         base_tokens_estimate: base_tokens,
         history_budget_tokens_estimate: budget,
         history_message_count: length(history)
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

  defp response_compaction_items(response) do
    metadata =
      Map.get(response, :response_metadata) || Map.get(response, "response_metadata") || %{}

    metadata
    |> Map.get(:context_compaction_items, Map.get(metadata, "context_compaction_items", []))
    |> normalize_items()
  end

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

  defp text_size(value) when is_binary(value), do: String.length(value)

  defp text_size(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.map(&text_size/1)
    |> Enum.sum()
  end

  defp text_size(value) when is_list(value), do: value |> Enum.map(&text_size/1) |> Enum.sum()
  defp text_size(value) when is_atom(value), do: value |> Atom.to_string() |> String.length()
  defp text_size(value) when is_number(value), do: value |> to_string() |> String.length()
  defp text_size(nil), do: 0
  defp text_size(value), do: value |> inspect(limit: 10, printable_limit: 500) |> String.length()

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
