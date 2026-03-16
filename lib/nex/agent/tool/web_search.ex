defmodule Nex.Agent.Tool.WebSearch do
  @moduledoc """
  Web Search Tool - Search the web using DuckDuckGo Instant Answer API (free, no API key required)
  """

  @behaviour Nex.Agent.Tool.Behaviour

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

  def execute(%{"query" => query, "count" => count}, _opts) when is_integer(count) do
    do_search(query, count)
  end

  def execute(%{"query" => query}, _opts) do
    do_search(query, 5)
  end

  defp do_search(query, count) do
    params = %{
      "q" => query,
      "format" => "json",
      "no_html" => 1,
      "skip_disambig" => 1,
      "count" => count
    }

    case Req.get(@ddg_url, params: params, follow_redirects: true) do
      {:ok, %{status: 200, body: body}} ->
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
end
