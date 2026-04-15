defmodule Nex.Agent.LLM.ReqLLM do
  @moduledoc false

  @behaviour Nex.Agent.LLM.Behaviour
  require Logger

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.Tool
  alias ReqLLM.ToolCall
  alias Nex.Agent.LLM.ProviderProfile

  @chat_timeout 180_000

  def chat(messages, options) do
    provider = Keyword.get(options, :provider, :anthropic)
    profile = ProviderProfile.for(provider, options)
    model_spec = resolve_model(profile, options)
    {req_messages, prepared_options} =
      messages
      |> sanitize_messages()
      |> prepare_messages_and_options(profile, options)

    req_options = build_req_llm_options(prepared_options)
    started_at = System.monotonic_time(:millisecond)

    generate_text_fun =
      Keyword.get(options, :req_llm_generate_text_fun) || (&ReqLLM.generate_text/3)

    Logger.info(
      "[ReqLLM] chat start model=#{model_spec_log(model_spec)} " <>
        "messages=#{req_message_stats(req_messages)} options=#{req_options_log(req_options)}"
    )

    try do
      case generate_text_fun.(model_spec, req_messages, req_options) do
        {:ok, response} ->
          parsed = parse_response(response)
          duration_ms = System.monotonic_time(:millisecond) - started_at

          Logger.info(
            "[ReqLLM] chat success duration_ms=#{duration_ms} response=#{response_log(parsed)}"
          )

          {:ok, parsed}

        {:error, reason} ->
          normalized = normalize_error(reason)
          duration_ms = System.monotonic_time(:millisecond) - started_at

          Logger.error(
            "[ReqLLM] chat error duration_ms=#{duration_ms} reason=#{error_log(normalized)}"
          )

          {:error, normalized}
      end
    rescue
      error ->
        normalized = normalize_error(error)
        duration_ms = System.monotonic_time(:millisecond) - started_at

        Logger.error(
          "[ReqLLM] chat rescue duration_ms=#{duration_ms} reason=#{error_log(normalized)}"
        )

        {:error, normalized}
    end
  end

  def stream(messages, options, callback) do
    provider = Keyword.get(options, :provider, :anthropic)
    profile = ProviderProfile.for(provider, options)
    model_spec = resolve_model(profile, options)
    {req_messages, prepared_options} =
      messages
      |> sanitize_messages()
      |> prepare_messages_and_options(profile, options)

    req_options = build_req_llm_options(prepared_options)
    stream_text_fun = Keyword.get(options, :req_llm_stream_text_fun) || (&ReqLLM.stream_text/3)
    started_at = System.monotonic_time(:millisecond)

    Logger.info(
      "[ReqLLM] stream start model=#{model_spec_log(model_spec)} " <>
        "messages=#{req_message_stats(req_messages)} options=#{req_options_log(req_options)}"
    )

    try do
      case stream_text_fun.(model_spec, req_messages, req_options) do
        {:ok, %StreamResponse{} = response} ->
          state =
            Enum.reduce(response.stream, %{tool_calls: []}, fn chunk, acc ->
              handle_stream_chunk(chunk, callback, acc)
            end)

          emit_stream_done(callback, Enum.reverse(state.tool_calls), %{
            finish_reason: normalize_finish_reason(StreamResponse.finish_reason(response)),
            usage: StreamResponse.usage(response),
            model: extract_stream_model(response)
          })

          duration_ms = System.monotonic_time(:millisecond) - started_at

          Logger.info(
            "[ReqLLM] stream success duration_ms=#{duration_ms} tool_calls=#{length(state.tool_calls)} " <>
              "model=#{inspect(extract_stream_model(response))}"
          )

          :ok

        {:ok, response} when is_map(response) ->
          state =
            Enum.reduce(
              Map.get(response, :stream) || Map.get(response, "stream") || [],
              %{tool_calls: []},
              fn chunk, acc ->
                handle_stream_chunk(chunk, callback, acc)
              end
            )

          emit_stream_done(callback, Enum.reverse(state.tool_calls), %{
            finish_reason:
              normalize_finish_reason(
                Map.get(response, :finish_reason) || Map.get(response, "finish_reason")
              ),
            usage: Map.get(response, :usage) || Map.get(response, "usage"),
            model: extract_stream_model(response)
          })

          duration_ms = System.monotonic_time(:millisecond) - started_at

          Logger.info(
            "[ReqLLM] stream success duration_ms=#{duration_ms} tool_calls=#{length(state.tool_calls)} " <>
              "model=#{inspect(extract_stream_model(response))}"
          )

          :ok

        {:error, reason} ->
          error = normalize_error(reason)
          duration_ms = System.monotonic_time(:millisecond) - started_at
          Logger.error("[ReqLLM] stream error duration_ms=#{duration_ms} reason=#{error_log(error)}")
          callback.({:error, error})
          {:error, error}
      end
    rescue
      error ->
        normalized = normalize_error(error)
        duration_ms = System.monotonic_time(:millisecond) - started_at
        Logger.error(
          "[ReqLLM] stream rescue duration_ms=#{duration_ms} reason=#{error_log(normalized)}"
        )
        callback.({:error, normalized})
        {:error, normalized}
    end
  end

  def tools, do: []

  defp prepare_messages_and_options(messages, profile, options) do
    {prepared_messages, prepared_options} =
      ProviderProfile.prepare_messages_and_options(messages, profile, options)

    {transform_messages(prepared_messages), prepared_options}
  end

  defp sanitize_messages(messages) do
    Enum.map(messages, fn message ->
      message
      |> Map.take(["role", "content", "tool_calls", "tool_call_id", "name", "reasoning_content"])
      |> drop_nil_values()
    end)
  end

  defp transform_messages(messages) do
    Enum.map(messages, fn message ->
      case message["role"] do
        "system" ->
          build_message(:system, message["content"])

        "assistant" ->
          content = message["content"]
          tool_calls = to_req_llm_tool_calls(message["tool_calls"] || [])

          opts =
            []
            |> maybe_put_keyword(:tool_calls, tool_calls != [], tool_calls)
            |> maybe_put_keyword(
              :metadata,
              present?(message["reasoning_content"]),
              %{reasoning_content: message["reasoning_content"]}
            )

          build_message(:assistant, content, opts)

        "tool" ->
          Context.tool_result(
            message["tool_call_id"] || generate_tool_call_id(),
            message["name"] || "tool",
            to_req_llm_content(message["content"])
          )

        _ ->
          build_message(:user, message["content"])
      end
    end)
  end

  defp build_req_llm_options(options) do
    provider = Keyword.get(options, :provider, :anthropic)
    profile = ProviderProfile.for(provider, options)
    {api_key, should_include_api_key} = ProviderProfile.api_key_config(profile, options)

    []
    |> maybe_put_keyword(:api_key, should_include_api_key, api_key)
    |> maybe_put_keyword(:base_url, present?(profile.base_url), profile.base_url)
    |> maybe_put_keyword(:temperature, is_number(options[:temperature]), options[:temperature])
    |> maybe_put_keyword(:max_tokens, is_integer(options[:max_tokens]), options[:max_tokens])
    |> maybe_put_keyword(:tools, true, transform_tools(options[:tools] || []))
    |> maybe_put_keyword(
      :tool_choice,
      not is_nil(options[:tool_choice]),
      normalize_tool_choice(options[:tool_choice])
    )
    |> maybe_put_keyword(:receive_timeout, true, @chat_timeout)
    |> maybe_put_keyword(
      :provider_options,
      true,
      ProviderProfile.provider_options(profile, options)
    )
  end

  defp transform_tools(tools) do
    tools
    |> Enum.map(&normalize_tool_definition/1)
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn %{name: name, description: description, parameter_schema: parameter_schema} ->
      Tool.new!(
        name: name,
        description: description,
        parameter_schema: parameter_schema,
        callback: fn _args -> {:ok, "Tool execution is handled by NexAgent"} end
      )
    end)
  end

  defp normalize_tool_definition(tool) when is_map(tool) do
    function = Map.get(tool, "function") || Map.get(tool, :function) || %{}

    name =
      Map.get(tool, "name") ||
        Map.get(tool, :name) ||
        Map.get(function, "name") ||
        Map.get(function, :name)

    description =
      Map.get(tool, "description") ||
        Map.get(tool, :description) ||
        Map.get(function, "description") ||
        Map.get(function, :description) || ""

    parameter_schema =
      Map.get(tool, "input_schema") ||
        Map.get(tool, :input_schema) ||
        Map.get(tool, "parameters") ||
        Map.get(tool, :parameters) ||
        Map.get(function, "input_schema") ||
        Map.get(function, :input_schema) ||
        Map.get(function, "parameters") ||
        Map.get(function, :parameters) || %{}

    if is_binary(name) and name != "" do
      %{
        name: name,
        description: to_string(description),
        parameter_schema: normalize_parameter_schema(parameter_schema)
      }
    else
      Logger.warning("[ReqLLM] Dropping invalid tool definition (missing name): #{inspect(tool)}")
      nil
    end
  end

  defp normalize_tool_definition(_), do: nil

  defp normalize_parameter_schema(schema) when is_map(schema), do: schema
  defp normalize_parameter_schema(_), do: %{}

  defp resolve_model(profile, options) do
    provider = Keyword.get(options, :provider, :anthropic)
    model = Keyword.get(options, :model) || default_model(provider)
    ProviderProfile.model_spec(profile, model)
  end

  defp parse_response(%Response{} = response) do
    classified = Response.classify(response)
    reasoning_content = normalized_reasoning_content(classified.thinking, classified.text)
    content = sanitize_final_content(classified.text)

    %{
      content: content,
      reasoning_content: reasoning_content,
      tool_calls: normalize_tool_calls(classified.tool_calls),
      finish_reason: normalize_finish_reason(classified.finish_reason),
      model: extract_model(response),
      usage: Response.usage(response)
    }
  end

  defp parse_response(response) when is_map(response) do
    raw_content =
      Map.get(response, :content) || Map.get(response, "content") || Map.get(response, :text) ||
        Map.get(response, "text")

    raw_reasoning =
      Map.get(response, :reasoning_content) || Map.get(response, "reasoning_content") ||
        Map.get(response, :thinking) || Map.get(response, "thinking")

    %{
      content: sanitize_final_content(raw_content),
      reasoning_content: normalized_reasoning_content(raw_reasoning, raw_content),
      tool_calls:
        normalize_tool_calls(
          Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || []
        ),
      finish_reason:
        normalize_finish_reason(
          Map.get(response, :finish_reason) || Map.get(response, "finish_reason")
        ),
      model: extract_model(response),
      usage: Map.get(response, :usage) || Map.get(response, "usage")
    }
  end

  defp emit_stream_done(callback, tool_calls, metadata) do
    if tool_calls != [] do
      callback.({:tool_calls, tool_calls})
    end

    callback.({:done, metadata})
  end

  defp handle_stream_chunk(chunk, callback, state) do
    case normalize_stream_event(chunk) do
      {:delta, text} ->
        callback.({:delta, text})
        state

      {:thinking, text} ->
        callback.({:thinking, text})
        state

      {:tool_call, tool_call} ->
        %{state | tool_calls: [tool_call | state.tool_calls]}

      nil ->
        state
    end
  end

  defp normalize_stream_event(%StreamChunk{type: :content, text: text}) when is_binary(text),
    do: {:delta, text}

  defp normalize_stream_event(%StreamChunk{type: :thinking, text: text}) when is_binary(text),
    do: {:thinking, text}

  defp normalize_stream_event(%StreamChunk{
         type: :tool_call,
         name: name,
         arguments: arguments,
         metadata: metadata
       }) do
    id =
      Map.get(metadata || %{}, :id) || Map.get(metadata || %{}, "id") || generate_tool_call_id()

    {:tool_call, normalize_tool_call(%{id: id, name: name, arguments: arguments || %{}})}
  end

  defp normalize_stream_event(%StreamChunk{}), do: nil

  defp normalize_stream_event(%{type: :content, text: text}) when is_binary(text),
    do: {:delta, text}

  defp normalize_stream_event(%{type: :thinking, text: text}) when is_binary(text),
    do: {:thinking, text}

  defp normalize_stream_event(%{type: :tool_call, name: name, arguments: arguments} = chunk) do
    id = Map.get(chunk, :id) || Map.get(chunk, "id") || generate_tool_call_id()
    {:tool_call, normalize_tool_call(%{id: id, name: name, arguments: arguments || %{}})}
  end

  defp normalize_stream_event(_), do: nil

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, &normalize_tool_call/1)
  end

  defp normalize_tool_calls(_), do: []

  defp to_req_llm_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      normalized = normalize_tool_call(tool_call)

      ToolCall.new(
        normalized["id"],
        normalized["function"]["name"],
        normalized["function"]["arguments"]
      )
    end)
  end

  defp to_req_llm_tool_calls(_), do: []

  defp normalize_tool_call(%ToolCall{} = tool_call) do
    %{
      "id" => tool_call.id,
      "type" => "function",
      "function" => %{
        "name" => tool_call.function.name,
        "arguments" => tool_call.function.arguments
      }
    }
  end

  defp normalize_tool_call(%{function: %{name: name, arguments: arguments}} = tool_call) do
    %{
      "id" => Map.get(tool_call, :id) || generate_tool_call_id(),
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => encode_arguments(arguments)
      }
    }
  end

  defp normalize_tool_call(
         %{"function" => %{"name" => name, "arguments" => arguments}} = tool_call
       ) do
    %{
      "id" => Map.get(tool_call, "id") || generate_tool_call_id(),
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => encode_arguments(arguments)
      }
    }
  end

  defp normalize_tool_call(%{name: name, arguments: arguments} = tool_call) do
    %{
      "id" => Map.get(tool_call, :id) || generate_tool_call_id(),
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => encode_arguments(arguments)
      }
    }
  end

  defp normalize_tool_call(%{"name" => name, "arguments" => arguments} = tool_call) do
    %{
      "id" => Map.get(tool_call, "id") || generate_tool_call_id(),
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => encode_arguments(arguments)
      }
    }
  end

  defp normalize_tool_call(other) do
    %{
      "id" => generate_tool_call_id(),
      "type" => "function",
      "function" => %{
        "name" => "unknown",
        "arguments" => encode_arguments(other)
      }
    }
  end

  defp normalize_tool_choice(nil), do: nil
  defp normalize_tool_choice(choice) when is_map(choice), do: choice
  defp normalize_tool_choice(choice) when is_binary(choice), do: choice
  defp normalize_tool_choice(choice) when is_atom(choice), do: Atom.to_string(choice)
  defp normalize_tool_choice(choice), do: choice

  defp normalize_finish_reason(nil), do: nil
  defp normalize_finish_reason(reason) when is_binary(reason), do: reason
  defp normalize_finish_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_finish_reason(reason), do: to_string(reason)

  defp normalize_error(%{message: _} = error), do: error
  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)

  defp model_spec_log(%{id: id, provider: provider, base_url: base_url}) do
    inspect(%{id: id, provider: provider, base_url: base_url})
  end

  defp model_spec_log(other), do: inspect(other)

  defp req_message_stats(messages) when is_list(messages) do
    counts =
      Enum.reduce(messages, %{}, fn msg, acc ->
        role =
          cond do
            is_map(msg) and Map.has_key?(msg, :role) -> Map.get(msg, :role)
            is_map(msg) and Map.has_key?(msg, "role") -> Map.get(msg, "role")
            true -> "unknown"
          end

        Map.update(acc, role, 1, &(&1 + 1))
      end)

    content_chars =
      Enum.reduce(messages, 0, fn msg, acc ->
        acc + message_content_chars(msg)
      end)

    inspect(%{total: length(messages), role_counts: counts, content_chars: content_chars})
  end

  defp req_options_log(options) when is_list(options) do
    inspect(%{
      base_url: options[:base_url],
      api_key_present: present?(options[:api_key]),
      temperature: options[:temperature],
      max_tokens: options[:max_tokens],
      tool_count: length(options[:tools] || []),
      tool_choice: options[:tool_choice],
      receive_timeout: options[:receive_timeout],
      provider_options: redact_provider_options(options[:provider_options])
    })
  end

  defp response_log(response) when is_map(response) do
    content = Map.get(response, :content) || Map.get(response, "content") || ""
    reasoning = Map.get(response, :reasoning_content) || Map.get(response, "reasoning_content") || ""
    tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || []
    usage = Map.get(response, :usage) || Map.get(response, "usage")

    inspect(%{
      model: Map.get(response, :model) || Map.get(response, "model"),
      finish_reason: Map.get(response, :finish_reason) || Map.get(response, "finish_reason"),
      content_chars: byte_size(to_text(content)),
      reasoning_chars: byte_size(to_text(reasoning)),
      tool_call_count: if(is_list(tool_calls), do: length(tool_calls), else: 0),
      usage: usage,
      preview: String.slice(to_text(content), 0, 160)
    })
  end

  defp error_log(error) when is_map(error) do
    inspect(Map.take(error, [:message, :status, :reason, "message", "status", "reason"]))
  end

  defp error_log(error), do: inspect(error)

  defp message_content_chars(%{content: content}), do: byte_size(to_text(content))
  defp message_content_chars(%{"content" => content}), do: byte_size(to_text(content))
  defp message_content_chars(_), do: 0

  defp redact_provider_options(options) when is_list(options) do
    Enum.map(options, fn
      {key, _value} when key in [:access_token, :api_key, :refresh_token, :authorization] ->
        {key, "[REDACTED]"}

      {key, value} ->
        {key, redact_provider_options(value)}

      other ->
        redact_provider_options(other)
    end)
  end

  defp redact_provider_options(options) when is_map(options) do
    Map.new(options, fn
      {key, _value} when key in [:access_token, :api_key, :refresh_token, :authorization] ->
        {key, "[REDACTED]"}

      {key, _value}
      when key in ["access_token", "api_key", "refresh_token", "authorization"] ->
        {key, "[REDACTED]"}

      {key, value} ->
        {key, redact_provider_options(value)}
    end)
  end

  defp redact_provider_options(value), do: value

  defp extract_model(%Response{model: model}), do: model
  defp extract_model(%{model: model}), do: model
  defp extract_model(%{"model" => model}), do: model
  defp extract_model(_), do: nil

  defp extract_stream_model(%StreamResponse{model: model}) when is_map(model),
    do: Map.get(model, :id) || Map.get(model, "id")

  defp extract_stream_model(%{model: model}) when is_binary(model), do: model
  defp extract_stream_model(%{"model" => model}) when is_binary(model), do: model

  defp extract_stream_model(%{model: model}) when is_map(model),
    do: Map.get(model, :id) || Map.get(model, "id")

  defp extract_stream_model(_), do: nil

  defp maybe_put_keyword(opts, _key, false, _value), do: opts
  defp maybe_put_keyword(opts, _key, _condition, nil), do: opts
  defp maybe_put_keyword(opts, key, _condition, value), do: Keyword.put(opts, key, value)

  defp build_message(role, content, opts \\ [])

  defp build_message(:system, content, _opts) do
    Context.system(to_req_llm_content(content))
  end

  defp build_message(:user, content, _opts) do
    Context.user(to_req_llm_content(content))
  end

  defp build_message(:assistant, content, opts) do
    Context.assistant(to_req_llm_content(content), opts)
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp encode_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_arguments(arguments), do: Jason.encode!(arguments || %{})

  defp to_text(nil), do: ""
  defp to_text(text) when is_binary(text), do: text

  defp to_text(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{"type" => "text", "text" => text} -> text
      %{type: "text", text: text} -> text
      other when is_binary(other) -> other
      _ -> ""
    end)
  end

  defp to_text(other), do: to_string(other)

  defp to_req_llm_content(content) when is_binary(content), do: content
  defp to_req_llm_content(nil), do: ""

  defp to_req_llm_content(content) when is_list(content) do
    Enum.map(content, &to_content_part/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      parts -> parts
    end
  end

  defp to_req_llm_content(other), do: to_text(other)

  defp to_content_part(%{"type" => "text", "text" => text}) when is_binary(text),
    do: ContentPart.text(text)

  defp to_content_part(%{type: "text", text: text}) when is_binary(text),
    do: ContentPart.text(text)

  defp to_content_part(%{"type" => "image", "source" => %{"type" => "url", "url" => url}})
       when is_binary(url),
       do: ContentPart.image_url(url)

  defp to_content_part(%{
         type: "image",
         source: %{type: "url", url: url}
       })
       when is_binary(url),
       do: ContentPart.image_url(url)

  defp to_content_part(%ContentPart{} = part), do: part
  defp to_content_part(text) when is_binary(text), do: ContentPart.text(text)
  defp to_content_part(_), do: nil

  defp present?(value) when value in [nil, "", []], do: false
  defp present?(_), do: true

  defp sanitize_final_content(content) when is_binary(content) do
    content
    |> String.replace(~r/<think>.*?<\/think>\s*/s, "")
    |> String.trim()
  end

  defp sanitize_final_content(content), do: content

  defp normalized_reasoning_content(reasoning_content, content)
       when is_binary(reasoning_content) do
    reasoning_content =
      reasoning_content
      |> String.trim()

    if reasoning_content == "" do
      extract_think_block(content)
    else
      reasoning_content
    end
  end

  defp normalized_reasoning_content(_reasoning_content, content), do: extract_think_block(content)

  defp extract_think_block(content) when is_binary(content) do
    case Regex.run(~r/<think>\s*(.*?)\s*<\/think>/s, content, capture: :all_but_first) do
      [think] ->
        think
        |> String.trim()
        |> case do
          "" -> ""
          value -> value
        end

      _ ->
        ""
    end
  end

  defp extract_think_block(_), do: ""

  defp default_model(:anthropic), do: "claude-sonnet-4-20250514"
  defp default_model(:openai), do: "gpt-4o"
  defp default_model(:openai_codex), do: "gpt-5.3-codex"
  defp default_model(:openrouter), do: "anthropic/claude-3.5-sonnet"
  defp default_model(:ollama), do: "llama3.1"
  defp default_model(_), do: "gpt-4o"

  defp generate_tool_call_id do
    "call_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
