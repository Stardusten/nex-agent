defmodule Nex.Agent.Tool.Backends.OpenAICodex do
  @moduledoc false

  alias Nex.Agent.LLM.ProviderProfile
  alias Nex.Agent.LLM.Providers.OpenAICodex.Stream

  @default_model "gpt-5.5"

  @spec web_search(String.t(), pos_integer(), map(), map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def web_search(query, count, ctx, capability_config) when is_binary(query) do
    tool =
      %{
        "type" => "web_search",
        "external_web_access" => Map.get(capability_config, "mode", "live") == "live"
      }
      |> maybe_put_filters(Map.get(capability_config, "allowed_domains"))
      |> maybe_put_user_location(Map.get(capability_config, "user_location"))

    prompt = """
    You must use the web_search tool for this request.

    Search query: #{query}
    Maximum results to summarize: #{count}

    Return concise search results with titles, URLs, and snippets when available.
    """

    with {:ok, response} <- run_builtin_call(prompt, [tool], ctx),
         :ok <- require_tool_usage(response, "web_search") do
      {:ok, response.content}
    end
  end

  @spec image_generation(String.t(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def image_generation(prompt, ctx, capability_config) when is_binary(prompt) do
    tool = %{
      "type" => "image_generation",
      "output_format" => Map.get(capability_config, "output_format", "png")
    }

    request = """
    You must use the image_generation tool for this request.

    Prompt: #{prompt}

    Generate the image and return no additional prose beyond any required tool output.
    """

    with {:ok, response} <- run_builtin_call(request, [tool], ctx),
         images when is_list(images) and images != [] <- Map.get(response.metadata, :generated_images) do
      {:ok, %{generated_images: images, content: response.content}}
    else
      [] -> {:error, "image_generation backend returned no images"}
      {:error, _} = error -> error
      _ -> {:error, "image_generation backend returned no images"}
    end
  end

  defp run_builtin_call(prompt, tools, ctx) do
    opts =
      [
        provider: :openai_codex,
        model: backend_model(ctx),
        api_key: backend_api_key(ctx),
        base_url: backend_base_url(ctx),
        tools: tools,
        provider_options: [
          auth_mode: :oauth,
          access_token: backend_api_key(ctx),
          instructions: backend_instructions()
        ],
        max_tokens: 4096
      ]
      |> maybe_put_opt(:req_llm_stream_text_fun, Map.get(ctx, :req_llm_stream_text_fun) || Map.get(ctx, "req_llm_stream_text_fun"))

    messages = [
      %{"role" => "user", "content" => prompt}
    ]

    model_spec = %{
      id: backend_model(ctx),
      provider: :openai,
      base_url: backend_base_url(ctx)
    }

    case Stream.stream_text(model_spec, messages, opts) do
      {:ok, stream_response} ->
        text =
          stream_response.stream
          |> Enum.reduce([], fn
            %ReqLLM.StreamChunk{type: :content, text: text}, acc when is_binary(text) ->
              [text | acc]

            _, acc ->
              acc
          end)
          |> Enum.reverse()
          |> Enum.join()

        {:ok,
         %{
           content: text,
           metadata: %{
             finish_reason: ReqLLM.StreamResponse.finish_reason(stream_response),
             usage: ReqLLM.StreamResponse.usage(stream_response),
             model: stream_response.model.id
           }
         }}

      {:error, reason} -> {:error, to_error_string(reason)}
    end
  end

  defp require_tool_usage(%{metadata: metadata}, tool_name) when is_map(metadata) do
    usage = Map.get(metadata, :usage) || Map.get(metadata, "usage") || %{}
    tool_usage = Map.get(usage, :tool_usage) || Map.get(usage, "tool_usage") || %{}
    entry = Map.get(tool_usage, tool_name) || Map.get(tool_usage, String.to_atom(tool_name)) || %{}

    if Map.get(entry, :count) || Map.get(entry, "count") do
      :ok
    else
      {:error, "#{tool_name} backend call returned no recorded tool usage"}
    end
  end

  defp backend_model(ctx) do
    Map.get(ctx, :tool_backend_model) ||
      Map.get(ctx, "tool_backend_model") ||
      ProviderProfile.default_model(:openai_codex) ||
      @default_model
  end

  defp backend_api_key(ctx) do
    Map.get(ctx, :tool_backend_api_key) ||
      Map.get(ctx, "tool_backend_api_key") ||
      ProviderProfile.default_api_key(:openai_codex)
  end

  defp backend_base_url(ctx) do
    Map.get(ctx, :tool_backend_base_url) ||
      Map.get(ctx, "tool_backend_base_url") ||
      ProviderProfile.default_base_url(:openai_codex)
  end

  defp backend_instructions do
    "You are a backend helper that must use the provided tool and return concise tool results."
  end

  defp maybe_put_filters(tool, domains) when is_list(domains) and domains != [] do
    Map.put(tool, "filters", %{"allowed_domains" => domains})
  end

  defp maybe_put_filters(tool, _domains), do: tool

  defp maybe_put_user_location(tool, %{} = location) when map_size(location) > 0 do
    Map.put(tool, "user_location", Map.put(location, "type", "approximate"))
  end

  defp maybe_put_user_location(tool, _location), do: tool

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp to_error_string(reason) when is_binary(reason), do: reason
  defp to_error_string(reason), do: inspect(reason)
end
