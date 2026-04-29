defmodule Nex.Agent.LLM.Providers.OpenAICodex.ResponsesPolicy do
  @moduledoc false

  @spec prepare_context(ReqLLM.Context.t()) :: ReqLLM.Context.t()
  def prepare_context(%ReqLLM.Context{messages: messages} = context) do
    %{context | messages: Enum.map(messages, &strip_response_id_from_message/1)}
  end

  @spec prepare_options(keyword()) :: keyword()
  def prepare_options(opts) do
    Keyword.update(opts, :provider_options, [], fn provider_options ->
      drop_option(provider_options, :previous_response_id)
    end)
  end

  @spec apply_body(map(), keyword()) :: map()
  def apply_body(body, opts) when is_map(body) do
    body
    |> put_instructions(opts)
    |> put_tool_choice(opts)
    |> put_context_management(opts)
    |> put_context_compaction_items(opts)
    |> apply_payload_policy()
  end

  @spec compaction_chunks(map()) :: [ReqLLM.StreamChunk.t()]
  def compaction_chunks(event) when is_map(event) do
    case extract_compaction_items(event) do
      [] -> []
      items -> [ReqLLM.StreamChunk.meta(%{context_compaction_items: items})]
    end
  end

  def compaction_chunks(_event), do: []

  defp strip_response_id_from_message(
         %ReqLLM.Message{role: :assistant, metadata: metadata} = message
       ) do
    %{message | metadata: drop_response_id(metadata)}
  end

  defp strip_response_id_from_message(message), do: message

  defp drop_response_id(metadata) when is_map(metadata) do
    metadata
    |> Map.delete(:response_id)
    |> Map.delete("response_id")
  end

  defp drop_response_id(metadata), do: metadata

  defp drop_option(options, key) when is_list(options) do
    string_key = Atom.to_string(key)
    Enum.reject(options, fn {option_key, _value} -> option_key in [key, string_key] end)
  end

  defp drop_option(options, key) when is_map(options) do
    options
    |> Map.delete(key)
    |> Map.delete(Atom.to_string(key))
  end

  defp drop_option(options, _key), do: options

  defp put_instructions(body, opts) do
    case get_provider_option(opts, :instructions) do
      instructions when is_binary(instructions) and instructions != "" ->
        Map.put(body, "instructions", instructions)

      _ ->
        body
    end
  end

  defp put_tool_choice(%{"tool_choice" => _} = body, _opts), do: body

  defp put_tool_choice(body, opts) do
    case Keyword.get(opts, :tool_choice) do
      %{type: "tool", name: name} when is_binary(name) and name != "" ->
        Map.put(body, "tool_choice", %{"type" => "function", "name" => name})

      %{"type" => "tool", "name" => name} when is_binary(name) and name != "" ->
        Map.put(body, "tool_choice", %{"type" => "function", "name" => name})

      %{type: :tool, name: name} when is_binary(name) and name != "" ->
        Map.put(body, "tool_choice", %{"type" => "function", "name" => name})

      _ ->
        body
    end
  end

  defp put_context_management(%{"context_management" => _} = body, _opts), do: body

  defp put_context_management(body, opts) do
    case get_provider_option(opts, :context_management) do
      value when is_list(value) and value != [] ->
        Map.put(body, "context_management", stringify_value(value))

      value when is_map(value) ->
        Map.put(body, "context_management", stringify_value(value))

      _ ->
        body
    end
  end

  defp put_context_compaction_items(body, opts) do
    items =
      opts
      |> get_provider_option(:context_compaction_items)
      |> normalize_compaction_items()

    case {items, Map.get(body, "input")} do
      {[], _input} -> body
      {items, input} when is_list(input) -> Map.put(body, "input", items ++ input)
      {_items, _input} -> body
    end
  end

  defp apply_payload_policy(body) do
    body
    |> Map.delete("previous_response_id")
    |> Map.delete("max_output_tokens")
    |> Map.put("store", false)
    |> strip_reasoning_item_ids()
  end

  defp strip_reasoning_item_ids(%{"input" => input} = body) when is_list(input) do
    Map.put(body, "input", Enum.map(input, &strip_reasoning_item_id/1))
  end

  defp strip_reasoning_item_ids(body), do: body

  defp strip_reasoning_item_id(%{"type" => "reasoning"} = item), do: Map.delete(item, "id")
  defp strip_reasoning_item_id(item), do: item

  defp get_provider_option(opts, key) do
    opts
    |> Keyword.get(:provider_options, [])
    |> get_option(key)
  end

  defp get_option(options, key) when is_list(options), do: Keyword.get(options, key)

  defp get_option(options, key) when is_map(options) do
    Map.get(options, key) || Map.get(options, Atom.to_string(key))
  end

  defp get_option(_options, _key), do: nil

  defp extract_compaction_items(event) do
    data = event_data(event)

    [data_item(data) | response_output_items(data)]
    |> normalize_compaction_items()
  end

  defp event_data(%{data: data}) when is_map(data), do: data
  defp event_data(%{"data" => data}) when is_map(data), do: data
  defp event_data(data) when is_map(data), do: data
  defp event_data(_data), do: %{}

  defp data_item(data) when is_map(data), do: Map.get(data, "item") || Map.get(data, :item)
  defp data_item(_data), do: nil

  defp response_output_items(data) when is_map(data) do
    response = Map.get(data, "response") || Map.get(data, :response) || %{}

    output =
      Map.get(response, "output") || Map.get(response, :output) || Map.get(data, "output") || []

    if is_list(output), do: output, else: []
  end

  defp response_output_items(_data), do: []

  defp normalize_compaction_items(items) when is_list(items) do
    items
    |> Enum.filter(&compaction_item?/1)
    |> Enum.map(&stringify_value/1)
    |> uniq_items()
  end

  defp normalize_compaction_items(item) when is_map(item) do
    normalize_compaction_items([item])
  end

  defp normalize_compaction_items(_items), do: []

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

  defp stringify_value(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
