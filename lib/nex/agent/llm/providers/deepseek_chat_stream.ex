defmodule Nex.Agent.LLM.Providers.DeepSeekChatStream do
  @moduledoc false

  @spec stream_text(ReqLLM.model_input(), ReqLLM.Context.prompt(), keyword()) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  def stream_text(model_spec, messages, opts \\ []) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(messages, opts) do
      ReqLLM.Streaming.start_stream(__MODULE__, model, context, opts)
    end
  end

  @spec attach_stream(LLMDB.Model.t(), ReqLLM.Context.t(), keyword(), atom()) ::
          {:ok, Finch.Request.t()} | {:error, term()}
  def attach_stream(model, context, opts, finch_name) do
    with {:ok, request} <-
           ReqLLM.Providers.OpenAI.ChatAPI.attach_stream(model, context, opts, finch_name) do
      {:ok, rewrite_request_body(request)}
    end
  end

  @spec decode_stream_event(map(), LLMDB.Model.t()) :: [ReqLLM.StreamChunk.t()]
  def decode_stream_event(event, model) do
    ReqLLM.Providers.OpenAI.decode_stream_event(event, model)
  end

  @spec decode_stream_event(map(), LLMDB.Model.t(), term()) :: {[ReqLLM.StreamChunk.t()], term()}
  def decode_stream_event(event, model, state) do
    ReqLLM.Providers.OpenAI.decode_stream_event(event, model, state)
  end

  defp rewrite_request_body(%Finch.Request{body: body} = request) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        %{request | body: Jason.encode!(rewrite_body(decoded))}

      _ ->
        request
    end
  end

  defp rewrite_request_body(request), do: request

  defp rewrite_body(%{"messages" => messages} = body) when is_list(messages) do
    Map.put(body, "messages", Enum.map(messages, &rewrite_message/1))
  end

  defp rewrite_body(%{messages: messages} = body) when is_list(messages) do
    Map.put(body, :messages, Enum.map(messages, &rewrite_message/1))
  end

  defp rewrite_body(body), do: body

  defp rewrite_message(%{"role" => "assistant", "metadata" => metadata} = message)
       when is_map(metadata) do
    case Map.get(metadata, "reasoning_content") || Map.get(metadata, :reasoning_content) do
      reasoning_content when is_binary(reasoning_content) and reasoning_content != "" ->
        message
        |> Map.put("reasoning_content", reasoning_content)
        |> Map.delete("metadata")

      _ ->
        message
    end
  end

  defp rewrite_message(%{role: "assistant", metadata: metadata} = message)
       when is_map(metadata) do
    case Map.get(metadata, :reasoning_content) || Map.get(metadata, "reasoning_content") do
      reasoning_content when is_binary(reasoning_content) and reasoning_content != "" ->
        message
        |> Map.put(:reasoning_content, reasoning_content)
        |> Map.delete(:metadata)

      _ ->
        message
    end
  end

  defp rewrite_message(message), do: message
end
