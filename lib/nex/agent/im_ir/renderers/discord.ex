defmodule Nex.Agent.IMIR.Renderers.Discord do
  @moduledoc false

  alias Nex.Agent.IMIR
  alias Nex.Agent.IMIR.Block
  alias Nex.Agent.IMIR.Parser
  alias Nex.Agent.IMIR.RenderResult

  @max_embed_fields 25
  @max_field_name_length 256
  @max_field_value_length 1024
  @max_embed_text_length 6000
  @embed_only_content_max_length 160
  @table_modes [:raw, :ascii, :embed]

  @type table_mode :: :raw | :ascii | :embed

  @spec render(String.t(), keyword()) :: [RenderResult.t()]
  def render(text, opts \\ []) when is_binary(text) do
    table_mode = normalize_table_mode(Keyword.get(opts, :show_table_as, :ascii))
    parser = IMIR.new(:discord)
    {parser, emitted} = Parser.push(parser, text)
    {_parser, flushed} = Parser.flush(parser)

    (emitted ++ flushed)
    |> Enum.map(&render_block(&1, table_mode))
  end

  @spec render_text(String.t(), keyword()) :: String.t()
  def render_text(text, opts \\ []) when is_binary(text) do
    text
    |> render(opts)
    |> Enum.reject(& &1.new_message?)
    |> Enum.map(& &1.text)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @spec render_payload(String.t(), keyword()) :: %{
          content: String.t(),
          embeds: [map()],
          warnings: [term()]
        }
  def render_payload(text, opts \\ []) when is_binary(text) do
    results = text |> render(opts) |> Enum.reject(& &1.new_message?)

    content =
      results
      |> Enum.reject(&embed_payload?/1)
      |> Enum.map(& &1.text)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    embeds =
      results
      |> Enum.map(& &1.payload)
      |> Enum.filter(&discord_embed?/1)

    warnings = Enum.flat_map(results, & &1.warnings)

    %{content: ensure_visible_embed_content(content, embeds), embeds: embeds, warnings: warnings}
  end

  defp render_block(%Block{} = block, table_mode) do
    {text, payload, warnings} =
      case block.type do
        :heading -> {block.canonical_text, block.canonical_text, []}
        :paragraph -> {block.text, block.text, []}
        :list -> {block.text, block.text, []}
        :quote -> text_payload(normalize_quote(block.text))
        :code_block -> text_payload(normalize_code_block(block))
        :table -> table_payload(block.rows, table_mode)
        :new_message -> {"", "", []}
      end

    RenderResult.from_block(block,
      payload: payload,
      text: text,
      warnings: warnings
    )
  end

  defp text_payload(text), do: {text, text, []}

  defp normalize_quote(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn
      ">" <> _ = line -> line
      line -> "> " <> line
    end)
    |> Enum.join("\n")
  end

  defp normalize_code_block(%Block{text: text, lang: lang}) do
    if String.starts_with?(text, "```") do
      text
    else
      lang = if is_binary(lang) and lang != "", do: lang, else: "text"
      "```#{lang}\n#{text}\n```"
    end
  end

  defp table_as_code_block(rows) do
    body =
      rows
      |> Enum.map(&String.trim/1)
      |> Enum.join("\n")

    "```text\n#{body}\n```"
  end

  defp table_as_raw(rows) do
    rows
    |> Enum.map(&String.trim/1)
    |> Enum.join("\n")
  end

  defp table_payload(rows, :raw) do
    raw = table_as_raw(rows)
    {raw, raw, [:discord_table_rendered_as_raw]}
  end

  defp table_payload(rows, :ascii) do
    case table_as_ascii(rows) do
      {:ok, ascii} -> {ascii, ascii, [:discord_table_rendered_as_ascii]}
      :error -> table_code_payload(rows)
    end
  end

  defp table_payload(rows, :embed) do
    fallback = table_as_code_block(rows)

    case table_as_embed(rows) do
      {:ok, embed} -> {fallback, embed, [:discord_table_degraded_to_embed_fields]}
      :error -> table_code_payload(rows)
    end
  end

  defp table_code_payload(rows) do
    fallback = table_as_code_block(rows)
    {fallback, fallback, [:discord_table_degraded_to_code_block]}
  end

  defp table_as_embed(rows) do
    with {:ok, headers, body_rows} <- parse_table(rows),
         true <- length(headers) <= @max_embed_fields,
         fields <- build_embed_fields(headers, body_rows),
         true <- fields != [],
         true <- embed_size(fields) <= @max_embed_text_length do
      {:ok, %{"fields" => fields}}
    else
      _ -> :error
    end
  end

  defp parse_table(rows) when is_list(rows) do
    parsed = Enum.map(rows, &parse_table_row/1)

    case parsed do
      [headers, separator | body_rows] ->
        cond do
          headers == [] or body_rows == [] -> :error
          not separator_row?(separator) -> :error
          true -> {:ok, headers, body_rows}
        end

      _ ->
        :error
    end
  end

  defp parse_table_row(row) do
    row
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|", trim: false)
    |> Enum.map(&String.trim/1)
  end

  defp separator_row?(cells) do
    cells != [] and Enum.all?(cells, &Regex.match?(~r/^:?-{3,}:?$/, &1))
  end

  defp table_as_ascii(rows) do
    with {:ok, headers, body_rows} <- parse_table(rows),
         true <- headers != [],
         true <- body_rows != [] do
      table_rows = [headers | body_rows]
      column_count = table_rows |> Enum.map(&length/1) |> Enum.max()
      widths = column_widths(table_rows, column_count)

      lines =
        [table_border(widths), table_row(headers, widths), table_border(widths)] ++
          Enum.map(body_rows, &table_row(&1, widths)) ++ [table_border(widths)]

      {:ok, "```text\n#{Enum.join(lines, "\n")}\n```"}
    else
      _ -> :error
    end
  end

  defp column_widths(rows, column_count) do
    for index <- 0..(column_count - 1) do
      rows
      |> Enum.map(fn row -> row |> Enum.at(index, "") |> display_width() end)
      |> Enum.max()
    end
  end

  defp table_border(widths) do
    "+" <> Enum.map_join(widths, "+", &String.duplicate("-", &1 + 2)) <> "+"
  end

  defp table_row(cells, widths) do
    content =
      widths
      |> Enum.with_index()
      |> Enum.map(fn {width, index} -> cells |> Enum.at(index, "") |> pad_cell(width) end)
      |> Enum.join(" | ")

    "| " <> content <> " |"
  end

  defp pad_cell(value, width) do
    text = to_string(value || "")
    text <> String.duplicate(" ", max(width - display_width(text), 0))
  end

  defp build_embed_fields(headers, body_rows) do
    headers
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {header, index}, acc ->
      name = header |> blank_to("Column #{index + 1}") |> truncate(@max_field_name_length)

      value =
        body_rows
        |> Enum.map(fn row -> row |> Enum.at(index, "") |> blank_to("-") end)
        |> Enum.join("\n")
        |> truncate(@max_field_value_length)

      if value == "" do
        {:halt, []}
      else
        {:cont, acc ++ [%{"name" => name, "value" => value, "inline" => true}]}
      end
    end)
  end

  defp embed_size(fields) do
    Enum.reduce(fields, 0, fn field, acc ->
      acc + String.length(field["name"]) + String.length(field["value"])
    end)
  end

  defp embed_payload?(%RenderResult{payload: payload}), do: discord_embed?(payload)

  defp discord_embed?(%{"fields" => fields}) when is_list(fields), do: true
  defp discord_embed?(_payload), do: false

  defp ensure_visible_embed_content("", [%{"fields" => fields} | _]) do
    fields
    |> Enum.map(&(Map.get(&1, "name") || Map.get(&1, :name)))
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" / ")
    |> case do
      "" -> "Table"
      headers -> "Table: " <> truncate(headers, @embed_only_content_max_length - 7)
    end
  end

  defp ensure_visible_embed_content(content, _embeds), do: content

  defp normalize_table_mode(mode) when is_atom(mode) and mode in @table_modes, do: mode

  defp normalize_table_mode(mode) when is_binary(mode) do
    mode
    |> String.trim()
    |> String.downcase()
    |> case do
      "raw" -> :raw
      "ascii" -> :ascii
      "embed" -> :embed
      _ -> :ascii
    end
  end

  defp normalize_table_mode(_mode), do: :ascii

  defp display_width(value) do
    value
    |> to_string()
    |> String.to_charlist()
    |> Enum.reduce(0, &(&2 + char_width(&1)))
  end

  defp char_width(char) when char < 0x20, do: 0
  defp char_width(char) when char >= 0x1100, do: 2
  defp char_width(_char), do: 1

  defp blank_to(value, fallback) do
    case String.trim(to_string(value || "")) do
      "" -> fallback
      text -> text
    end
  end

  defp truncate(text, max_length) do
    if String.length(text) <= max_length do
      text
    else
      String.slice(text, 0, max_length - 3) <> "..."
    end
  end
end
