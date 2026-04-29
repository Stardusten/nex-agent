defmodule Nex.Agent.Interface.IMIR.DiscordRendererTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Interface.IMIR.Renderers.Discord

  test "renderer preserves Discord-supported markdown blocks" do
    text =
      Discord.render_text("""
      # Title

      - item 1
      - item 2

      > quoted

      ```elixir
      IO.puts("hi")
      ```
      """)

    assert text =~ "# Title"
    assert text =~ "- item 1\n- item 2"
    assert text =~ "> quoted"
    assert text =~ "```elixir\nIO.puts(\"hi\")\n```"
  end

  test "renderer formats markdown tables as ascii by default" do
    payload =
      Discord.render_payload("""
      | name | score |
      | --- | --- |
      | alice | 10 |
      """)

    assert payload.content ==
             """
             ```text
             +-------+-------+
             | name  | score |
             +-------+-------+
             | alice | 10    |
             +-------+-------+
             ```
             """
             |> String.trim()

    assert payload.embeds == []
  end

  test "renderer can pass markdown tables through raw" do
    payload =
      Discord.render_payload(
        """
        | name | score |
        | --- | --- |
        | alice | 10 |
        """,
        show_table_as: :raw
      )

    assert payload.content == "| name | score |\n| --- | --- |\n| alice | 10 |"
    assert payload.embeds == []
  end

  test "renderer exposes markdown tables as embed fields with code-block text fallback" do
    results =
      Discord.render(
        """
        | name | score |
        | --- | --- |
        | alice | 10 |
        """,
        show_table_as: :embed
      )

    texts = Enum.map(results, & &1.text) |> Enum.reject(&(&1 == ""))
    combined = Enum.join(texts, "\n\n")
    assert combined =~ "| name | score |"
    assert combined =~ "```text"

    assert [%{"fields" => fields}] =
             results
             |> Enum.map(& &1.payload)
             |> Enum.filter(&match?(%{"fields" => _}, &1))

    assert %{"name" => "name", "value" => "alice", "inline" => true} in fields
    assert %{"name" => "score", "value" => "10", "inline" => true} in fields
  end

  test "render payload keeps table fallback text out of message content when embed works" do
    payload =
      Discord.render_payload(
        """
        Summary:

        | name | score |
        | --- | --- |
        | alice | 10 |
        """,
        show_table_as: :embed
      )

    assert payload.content == "Summary:"
    assert [%{"fields" => fields}] = payload.embeds
    assert %{"name" => "name", "value" => "alice", "inline" => true} in fields
  end

  test "render payload gives table-only embeds visible message content" do
    payload =
      Discord.render_payload(
        """
        | name | score |
        | --- | --- |
        | alice | 10 |
        """,
        show_table_as: :embed
      )

    assert payload.content == "Table: name / score"
    assert [%{"fields" => fields}] = payload.embeds
    assert %{"name" => "name", "value" => "alice", "inline" => true} in fields
  end

  test "renderer preserves Discord spoiler tags" do
    text = Discord.render_text("是直接 ||剧透|| ，而不是")
    assert text =~ "||剧透||"
    refute text =~ "```"
  end

  test "renderer keeps newmsg boundary out of rendered content" do
    assert Discord.render_text("before<newmsg/>after") == "before\n\nafter"
  end
end
