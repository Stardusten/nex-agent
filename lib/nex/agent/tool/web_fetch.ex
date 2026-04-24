defmodule Nex.Agent.Tool.WebFetch do
  @moduledoc """
  Web Fetch Tool - Fetch URL content with HTML parsing
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.HTTP

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @max_length 50_000

  def name, do: "web_fetch"
  def description, do: "Fetch and extract content from a URL."
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          url: %{
            type: "string",
            description: "URL to fetch"
          }
        },
        required: ["url"]
      }
    }
  end

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{
          "type" => "string",
          "description" => "URL to fetch"
        }
      },
      "required" => ["url"]
    }
  end

  def execute(%{"url" => url}, opts) do
    if valid_url?(url) do
      do_fetch(url, request_fun(opts), cancel_ref(opts), observe_context(opts))
    else
      {:ok, %{error: "Invalid URL: #{url}"}}
    end
  end

  defp valid_url?(url) do
    case URI.parse(url) do
      %{scheme: s, host: h} when s in ["http", "https"] and h != nil -> true
      _ -> false
    end
  end

  defp do_fetch(url, http_get, cancel_ref, observe_context) do
    headers = [
      {"User-Agent", @user_agent},
      {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"Accept-Language", "en-US,en;q=0.5"}
    ]

    req_opts =
      [headers: headers, max_redirects: 5, receive_timeout: 30_000]
      |> maybe_put_cancel_ref(cancel_ref)
      |> maybe_put_observe_context(observe_context)
      |> HTTP.maybe_add_proxy(url)

    case http_get.(url, req_opts) do
      {:ok, %{status: 200, body: body} = response} ->
        case ensure_text_body(response, body) do
          {:ok, text_body} ->
            content = extract_content(text_body, url)
            {:ok, content}

          {:error, reason} ->
            {:ok, %{error: reason}}
        end

      {:ok, %{status: status}} ->
        {:ok, %{error: "Failed to fetch: HTTP #{status}"}}

      {:error, reason} ->
        {:ok, %{error: "Failed to fetch: #{inspect(reason)}"}}
    end
  end

  defp request_fun(%{http_get: http_get}) when is_function(http_get, 2), do: http_get

  defp request_fun(opts) when is_list(opts),
    do: Keyword.get_lazy(opts, :http_get, fn -> &HTTP.get/2 end)

  defp request_fun(_opts), do: &HTTP.get/2

  defp cancel_ref(opts) when is_map(opts), do: Map.get(opts, :cancel_ref)
  defp cancel_ref(opts) when is_list(opts), do: Keyword.get(opts, :cancel_ref)
  defp cancel_ref(_opts), do: nil
  defp maybe_put_cancel_ref(opts, nil), do: opts
  defp maybe_put_cancel_ref(opts, cancel_ref), do: Keyword.put(opts, :cancel_ref, cancel_ref)

  defp observe_context(opts) when is_map(opts) do
    Map.take(opts, [:workspace, :run_id, :session_key, :channel, :chat_id, :tool_call_id])
  end

  defp observe_context(_opts), do: %{}

  defp maybe_put_observe_context(opts, context) when context == %{}, do: opts
  defp maybe_put_observe_context(opts, context), do: Keyword.put(opts, :observe_context, context)

  defp ensure_text_body(response, body) when is_binary(body) do
    content_type = response_content_type(response)

    cond do
      content_type != nil and not text_like_content_type?(content_type) ->
        {:error, "Unsupported non-text response content-type: #{content_type}"}

      not String.valid?(body) ->
        {:error, "Response body is not valid UTF-8 text"}

      true ->
        {:ok, body}
    end
  end

  defp ensure_text_body(_response, _body), do: {:error, "Response body is not text"}

  defp response_content_type(%{headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == "content-type", do: value

      _ ->
        nil
    end)
  end

  defp response_content_type(_), do: nil

  defp text_like_content_type?(content_type) when is_binary(content_type) do
    down = String.downcase(content_type)

    String.starts_with?(down, "text/") or
      String.contains?(down, "json") or
      String.contains?(down, "xml") or
      String.contains?(down, "javascript")
  end

  defp extract_content(html, url) when is_binary(html) do
    html
    |> strip_scripts()
    |> strip_styles()
    |> strip_tags()
    |> decode_entities()
    |> normalize_whitespace()
    |> truncate(@max_length)
    |> format_output(url)
  end

  defp strip_scripts(html) do
    Regex.replace(~r/<script[^>]*>[\s\S]*?<\/script>/i, html, "")
  end

  defp strip_styles(html) do
    Regex.replace(~r/<style[^>]*>[\s\S]*?<\/style>/i, html, "")
  end

  defp strip_tags(html) do
    Regex.replace(~r/<[\s\S]*?>/, html, " ")
  end

  defp decode_entities(html) do
    html
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/&#\d+;/, " ")
  end

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate(text, max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "\n\n... [truncated]"
    else
      text
    end
  end

  defp format_output(content, url) do
    """
    Source: #{url}

    #{content}
    """
  end
end
