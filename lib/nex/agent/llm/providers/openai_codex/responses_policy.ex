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
    |> rewrite_builtin_tools(opts)
    |> put_tool_choice(opts)
    |> apply_payload_policy()
  end

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

  defp rewrite_builtin_tools(%{"tools" => tools} = body, opts) when is_list(tools) do
    Map.put(body, "tools", Enum.map(tools, &rewrite_builtin_tool(&1, opts)))
  end

  defp rewrite_builtin_tools(body, _opts), do: body

  defp rewrite_builtin_tool(tool, _opts), do: tool

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
end
