defmodule Nex.Agent.Tool.WebSearch do
  @moduledoc """
  Web Search Tool - Search the web using DuckDuckGo Instant Answer API (free, no API key required)
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.HTTP

  @ddg_url "https://api.duckduckgo.com"

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
    do_search(query, count, request_fun(opts))
  end

  def execute(%{"query" => query}, opts) do
    do_search(query, 5, request_fun(opts))
  end

  defp do_search(query, count, http_get) do
    params = %{
      "q" => query,
      "format" => "json",
      "no_html" => 1,
      "skip_disambig" => 1,
      "count" => count
    }

    req_opts =
      [params: params, redirect: true]
      |> HTTP.maybe_add_proxy(@ddg_url)

    case http_get.(@ddg_url, req_opts) do
      {:ok, %{status: 200, body: body}} ->
        body = if is_binary(body), do: Jason.decode!(body), else: body
        results = parse_results(body)
        {:ok, results}

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

  defp request_fun(%{http_get: http_get}) when is_function(http_get, 2), do: http_get

  defp request_fun(opts) when is_list(opts),
    do: Keyword.get_lazy(opts, :http_get, fn -> &Req.get/2 end)

  defp request_fun(_opts), do: &Req.get/2
end
