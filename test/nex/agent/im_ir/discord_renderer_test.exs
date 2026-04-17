defmodule Nex.Agent.IMIR.DiscordRendererTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.IMIR.Renderers.Discord

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

  test "renderer passes through table-like text as paragraph since Discord profile has tables: false" do
    results =
      Discord.render("""
      | name | score |
      | --- | --- |
      | alice | 10 |
      """)

    texts = Enum.map(results, & &1.text) |> Enum.reject(&(&1 == ""))
    combined = Enum.join(texts, "\n\n")
    assert combined =~ "| name | score |"
    # No code block wrapping
    refute combined =~ "```text"
  end

  test "renderer preserves Discord spoiler tags" do
    text = Discord.render_text("是直接 ||剧透|| ，而不是")
    assert text =~ "||剧透||"
    refute text =~ "```"
  end

  test "renderer keeps newmsg boundary out of rendered content" do
    assert Discord.render_text("before\n<newmsg/>\nafter") == "before\n\nafter"
  end
end
