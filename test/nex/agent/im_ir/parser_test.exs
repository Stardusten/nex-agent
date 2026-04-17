defmodule Nex.Agent.IMIR.ParserTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.IMIR
  alias Nex.Agent.IMIR.Block
  alias Nex.Agent.IMIR.Parser

  test "parser incrementally emits new_message token outside code blocks" do
    parser = IMIR.new(:feishu)

    {parser, blocks1} = Parser.push(parser, "hello\n<new")
    assert blocks1 == [%Block{type: :paragraph, text: "hello", canonical_text: "hello"}]

    {parser, blocks2} = Parser.push(parser, "msg/>\nworld\n")

    assert [
             %Block{type: :new_message, canonical_text: "<newmsg/>"},
             %Block{type: :paragraph, text: "world", canonical_text: "world"}
           ] = blocks2

    {_parser, flushed} = Parser.flush(parser)
    assert flushed == []
  end

  test "parser does not split on new_message token inside fenced code blocks" do
    parser = IMIR.new(:feishu)

    {parser, blocks1} = Parser.push(parser, "```elixir\nIO.puts(\"<newmsg/>\")")
    assert blocks1 == []

    {parser, blocks2} = Parser.push(parser, "\n```\n")

    assert [
             %Block{
               type: :code_block,
               canonical_text: "```elixir\nIO.puts(\"<newmsg/>\")\n```",
               complete?: true
             }
           ] = blocks2

    {_parser, flushed} = Parser.flush(parser)
    assert flushed == []
  end

  test "parser marks unclosed code blocks as incomplete until flush" do
    parser = IMIR.new(:feishu)
    {parser, blocks} = Parser.push(parser, "```json\n{\"a\": 1}")

    assert blocks == []

    {_parser, flushed} = Parser.flush(parser)

    assert [
             %Block{
               type: :code_block,
               canonical_text: "```json\n{\"a\": 1}",
               complete?: false,
               lang: "json"
             }
           ] = flushed
  end

  test "parser keeps table rows together as a table block" do
    parser = IMIR.new(:feishu)

    {_parser, blocks} =
      Parser.push(
        parser,
        "| name | score |\n| --- | --- |\n| alice | 10 |\n"
      )

    assert [
             %Block{
               type: :table,
               rows: ["| name | score |", "| --- | --- |", "| alice | 10 |"],
               canonical_text: "| name | score |\n| --- | --- |\n| alice | 10 |"
             }
           ] = blocks
  end

  test "parser emits heading list quote and paragraph blocks" do
    parser = IMIR.new(:feishu)

    {_parser, blocks} =
      Parser.push(
        parser,
        "# Title\n- item 1\n- item 2\n> note\nplain text\n"
      )

    assert [
             %Block{type: :heading, level: 1, text: "Title", canonical_text: "# Title"},
             %Block{
               type: :list,
               items: ["- item 1", "- item 2"],
               canonical_text: "- item 1\n- item 2"
             },
             %Block{type: :quote, canonical_text: "> note"},
             %Block{type: :paragraph, canonical_text: "plain text"}
           ] = blocks
  end
end
