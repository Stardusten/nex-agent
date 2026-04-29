defmodule Nex.Agent.Interface.IMIR.Renderers.Feishu do
  @moduledoc false

  alias Nex.Agent.Interface.IMIR
  alias Nex.Agent.Interface.IMIR.Block
  alias Nex.Agent.Interface.IMIR.Parser
  alias Nex.Agent.Interface.IMIR.RenderResult

  @spec render(String.t()) :: [RenderResult.t()]
  def render(text) when is_binary(text) do
    parser = IMIR.new(:feishu)
    {parser, emitted} = Parser.push(parser, text)
    {_parser, flushed} = Parser.flush(parser)

    (emitted ++ flushed)
    |> Enum.map(&render_block/1)
  end

  @spec render_card(String.t()) :: map()
  def render_card(text) when is_binary(text) do
    %{
      "config" => %{"wide_screen_mode" => true},
      "elements" => render_elements(text)
    }
  end

  @spec render_elements(String.t()) :: [map()]
  def render_elements(text) when is_binary(text) do
    text
    |> render()
    |> Enum.flat_map(&render_result_to_elements/1)
  end

  defp render_block(%Block{} = block) do
    payload =
      case block.type do
        :heading -> heading_element(block)
        :paragraph -> markdown_component(block.text)
        :list -> markdown_component(block.text)
        :quote -> markdown_component("> " <> trim_quote_prefix(block.text))
        :code_block -> markdown_component(normalize_code_block(block))
        :table -> markdown_component(block.text)
        :new_message -> nil
      end

    warnings =
      case block.type do
        :table -> [:feishu_table_degraded_to_markdown]
        _ -> []
      end

    RenderResult.from_block(block,
      payload: payload,
      text: text_for_block(block),
      warnings: warnings
    )
  end

  defp render_result_to_elements(%RenderResult{payload: payload}) when is_list(payload),
    do: payload

  defp render_result_to_elements(%RenderResult{payload: nil}), do: []
  defp render_result_to_elements(%RenderResult{payload: payload}), do: [payload]

  defp heading_element(%Block{level: _level, text: text}) do
    markdown_component("# " <> text)
  end

  defp markdown_component(text) when is_binary(text) do
    %{
      "tag" => "markdown",
      "content" => text
    }
  end

  defp normalize_code_block(%Block{text: text, lang: lang}) do
    if String.starts_with?(text, "```") do
      text
    else
      lang = if is_binary(lang) and lang != "", do: lang, else: "text"
      "```#{lang}\n#{text}\n```"
    end
  end

  defp text_for_block(%Block{type: :new_message}), do: ""
  defp text_for_block(%Block{text: text}), do: text

  defp trim_quote_prefix(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim_leading(&1, "> "))
    |> Enum.join("\n")
  end
end
