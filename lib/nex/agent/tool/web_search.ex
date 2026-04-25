defmodule Nex.Agent.Tool.WebSearch do
  @moduledoc """
  Web Search Tool - Search the web using DuckDuckGo (free, no API key required)
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Config
  alias Nex.Agent.HTTP
  alias Nex.Agent.Tool.Backends.Codex

  @ddg_api_url "https://api.duckduckgo.com"
  @ddg_html_url "https://html.duckduckgo.com/html/"

  def name, do: "web_search"
  def description, do: "Search the web. Returns titles, URLs, and snippets."
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "Search query"
          },
          count: %{
            type: "integer",
            description: "Number of results (1-10)",
            minimum: 1,
            maximum: 10
          }
        },
        required: ["query"]
      }
    }
  end

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Search query"
        },
        "count" => %{
          "type" => "integer",
          "description" => "Number of results (1-10)",
          "minimum" => 1,
          "maximum" => 10
        }
      },
      "required" => ["query"]
    }
  end

  def execute(%{"query" => query, "count" => count}, opts) when is_integer(count) do
    execute_with_backend(query, count, opts)
  end

  def execute(%{"query" => query}, opts) do
    execute_with_backend(query, 5, opts)
  end

  defp execute_with_backend(query, count, opts) do
    backend_config = provider_config(opts)

    case Map.get(backend_config, "provider") do
      "duckduckgo" ->
        do_search(query, count, request_fun(opts), cancel_ref(opts), observe_context(opts))

      "codex" ->
        if Map.get(backend_config, "mode") == "disabled" do
          {:error, "web_search is disabled. [Analyze the error and try a different approach.]"}
        else
          Codex.web_search(query, count, normalize_ctx(opts), backend_config)
        end

      provider ->
        {:error, unsupported_provider_error("web_search", provider)}
    end
  end

  defp unsupported_provider_error(tool, provider),
    do:
      "#{tool} provider #{inspect(provider)} is not supported. [Analyze the error and try a different approach.]"

  defp do_search(query, count, http_get, cancel_ref, observe_context) do
    params = %{
      "q" => query,
      "format" => "json",
      "no_html" => 1,
      "skip_disambig" => 1,
      "count" => count
    }

    req_opts =
      [params: params, redirect: true]
      |> maybe_put_cancel_ref(cancel_ref)
      |> maybe_put_observe_context(observe_context)
      |> HTTP.maybe_add_proxy(@ddg_api_url)

    case http_get.(@ddg_api_url, req_opts) do
      {:ok, %{status: 200, body: body}} ->
        body = if is_binary(body), do: Jason.decode!(body), else: body
        results = parse_results(body)

        if empty_results?(results) do
          search_html(query, count, http_get, cancel_ref, observe_context)
        else
          {:ok, results}
        end

      {:ok, %{status: status, body: body}} ->
        {:ok, %{error: "Search failed with status #{status}: #{inspect(body)}"}}

      {:error, reason} ->
        case search_html(query, count, http_get, cancel_ref, observe_context) do
          {:ok, results} when is_binary(results) -> {:ok, results}
          _ -> {:ok, %{error: "Search failed: #{inspect(reason)}"}}
        end
    end
  end

  defp search_html(query, count, http_get, cancel_ref, observe_context) do
    req_opts =
      [params: %{"q" => query}, redirect: true]
      |> maybe_put_cancel_ref(cancel_ref)
      |> maybe_put_observe_context(observe_context)
      |> HTTP.maybe_add_proxy(@ddg_html_url)

    case http_get.(@ddg_html_url, req_opts) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, parse_html_results(body, count)}

      {:ok, %{status: status, body: body}} ->
        {:ok, %{error: "Search failed with status #{status}: #{inspect(body)}"}}

      {:error, reason} ->
        {:ok, %{error: "Search failed: #{inspect(reason)}"}}
    end
  end

  defp parse_results(body) do
    results = body["RelatedTopics"] || []

    formatted =
      Enum.map_join(results, "\n---\n", fn r ->
        title = r["Text"] || r["name"] || ""
        url = r["FirstURL"] || r["url"] || ""
        "#{title}\n#{url}\n"
      end)

    if formatted == "" do
      "No results found."
    else
      formatted
    end
  end

  defp empty_results?("No results found."), do: true
  defp empty_results?(""), do: true
  defp empty_results?(_), do: false

  defp parse_html_results(body, count) do
    ~r/<a\b[^>]*class="[^"]*\bresult__a\b[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/si
    |> Regex.scan(body)
    |> Enum.map(fn [_match, href, title] ->
      {clean_html(title), decode_ddg_href(href)}
    end)
    |> Enum.reject(fn {title, url} -> title == "" or url == "" end)
    |> Enum.uniq_by(fn {_title, url} -> url end)
    |> Enum.take(count)
    |> Enum.map_join("\n---\n", fn {title, url} -> "#{title}\n#{url}\n" end)
    |> case do
      "" -> "No results found."
      formatted -> formatted
    end
  end

  defp clean_html(value) do
    value
    |> String.replace(~r/<[^>]*>/, "")
    |> html_unescape()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp decode_ddg_href(href) do
    href = html_unescape(href)

    href
    |> URI.parse()
    |> case do
      %URI{query: query} when is_binary(query) ->
        query
        |> URI.decode_query()
        |> Map.get("uddg", href)

      _ ->
        href
    end
    |> normalize_url()
  end

  defp normalize_url("//" <> rest), do: "https://" <> rest
  defp normalize_url(url), do: url

  defp html_unescape(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
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

  defp provider_config(opts) when is_map(opts) do
    case Map.get(opts, :config) || Map.get(opts, "config") do
      %Config{} = config -> Config.web_search_provider_config(config)
      _ -> Config.web_search_provider_config(nil)
    end
  end

  defp provider_config(opts) when is_list(opts) do
    case Keyword.get(opts, :config) do
      %Config{} = config -> Config.web_search_provider_config(config)
      _ -> Config.web_search_provider_config(nil)
    end
  end

  defp provider_config(_opts), do: Config.web_search_provider_config(nil)

  defp normalize_ctx(opts) when is_map(opts), do: opts
  defp normalize_ctx(opts) when is_list(opts), do: Enum.into(opts, %{})
  defp normalize_ctx(_opts), do: %{}
end
