defmodule Nex.Agent.IMIR.DiscordRendererTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.IMIR.RenderResult
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

  test "renderer degrades tables to code blocks because Discord messages do not render tables" do
    [result] =
      Discord.render("""
      | name | score |
      | --- | --- |
      | alice | 10 |
      """)

    assert %RenderResult{text: text, warnings: [:discord_table_degraded_to_code_block]} = result
    assert text == "```text\n| name | score |\n| --- | --- |\n| alice | 10 |\n```"
  end

  test "renderer keeps newmsg boundary out of rendered content" do
    assert Discord.render_text("before\n<newmsg/>\nafter") == "before\n\nafter"
  end
end
