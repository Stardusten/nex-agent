defmodule Nex.Agent.LLM.Providers.OpenAICodex.Stream do
  @moduledoc false

  alias Nex.Agent.LLM.Providers.OpenAICodex.ResponsesPolicy

  @spec stream_text(ReqLLM.model_input(), ReqLLM.Context.prompt(), keyword()) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  def stream_text(model_spec, messages, opts \\ []) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(messages, opts) do
      ReqLLM.Streaming.start_stream(__MODULE__, model, context, opts)
    end
  end

  @spec attach_stream(LLMDB.Model.t(), ReqLLM.Context.t(), keyword(), atom()) ::
          {:ok, Finch.Request.t()} | {:error, Exception.t()}
  def attach_stream(model, context, opts, finch_name) do
    with {:ok, request} <-
           ReqLLM.Providers.OpenAI.ResponsesAPI.attach_stream(
             model,
             ResponsesPolicy.prepare_context(context),
             ResponsesPolicy.prepare_options(opts),
             finch_name
           ) do
      {:ok, rewrite_request_body(request, opts)}
    end
  end

  @spec init_stream_state(LLMDB.Model.t()) :: map()
  def init_stream_state(_model), do: ReqLLM.Providers.OpenAI.ResponsesAPI.init_stream_state()

  @spec decode_stream_event(map(), LLMDB.Model.t()) :: [ReqLLM.StreamChunk.t()]
  def decode_stream_event(event, model) do
    ReqLLM.Providers.OpenAI.ResponsesAPI.decode_stream_event(event, model)
  end

  @spec decode_stream_event(map(), LLMDB.Model.t(), map() | nil) ::
          {[ReqLLM.StreamChunk.t()], map()}
  def decode_stream_event(event, model, state) do
    ReqLLM.Providers.OpenAI.ResponsesAPI.decode_stream_event(event, model, state)
  end

  defp rewrite_request_body(%{body: raw_body} = request, opts) do
    body =
      raw_body
      |> IO.iodata_to_binary()
      |> Jason.decode!()
      |> ResponsesPolicy.apply_body(opts)

    %{request | body: Jason.encode!(body)}
  end
end
