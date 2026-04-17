defmodule Nex.Agent.IMIR.Renderers.Discord do
  @moduledoc false

  alias Nex.Agent.IMIR
  alias Nex.Agent.IMIR.Block
  alias Nex.Agent.IMIR.Parser
  alias Nex.Agent.IMIR.RenderResult

  @spec render(String.t()) :: [RenderResult.t()]
  def render(text) when is_binary(text) do
    parser = IMIR.new(:discord)
    {parser, emitted} = Parser.push(parser, text)
    {_parser, flushed} = Parser.flush(parser)

    (emitted ++ flushed)
    |> Enum.map(&render_block/1)
  end

  @spec render_text(String.t()) :: String.t()
  def render_text(text) when is_binary(text) do
    text
    |> render()
    |> Enum.reject(& &1.new_message?)
    |> Enum.map(& &1.text)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp render_block(%Block{} = block) do
    {text, warnings} =
      case block.type do
        :heading -> {block.canonical_text, []}
        :paragraph -> {block.text, []}
        :list -> {block.text, []}
        :quote -> {normalize_quote(block.text), []}
        :code_block -> {normalize_code_block(block), []}
        :table -> {table_as_code_block(block.rows), [:discord_table_degraded_to_code_block]}
        :new_message -> {"", []}
      end

    RenderResult.from_block(block,
      payload: text,
      text: text,
      warnings: warnings
    )
  end

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
end
