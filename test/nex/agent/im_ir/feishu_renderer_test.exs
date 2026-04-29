defmodule Nex.Agent.Interface.IMIR.FeishuRendererTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Interface.IMIR.RenderResult
  alias Nex.Agent.Interface.IMIR.Renderers.Feishu

  test "renderer builds card elements for heading list quote code and table" do
    elements =
      Feishu.render_elements("""
      # Title

      - item 1
      - item 2

      > quoted

      ```elixir
      IO.puts("hi")
      ```

      | name | score |
      | --- | --- |
      | alice | 10 |
      """)

    contents =
      elements
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn
        %{"content" => content} -> content
        %{"tag" => "hr"} -> :hr
        _ -> nil
      end)

    assert "# Title" in contents
    assert "- item 1\n- item 2" in contents
    assert "> quoted" in contents
    assert "```elixir\nIO.puts(\"hi\")\n```" in contents
    assert "| name | score |\n| --- | --- |\n| alice | 10 |" in contents
  end

  test "render_card wraps elements in interactive-compatible card payload" do
    card = Feishu.render_card("# Title\n\nnext")

    assert card["config"]["wide_screen_mode"] == true
    assert is_list(card["elements"])

    assert Enum.any?(
             card["elements"],
             &match?(%{"tag" => "markdown", "content" => "# Title"}, &1)
           )
  end

  test "renderer marks table output as deterministic degradation" do
    [result] =
      Feishu.render("""
      | name | score |
      | --- | --- |
      | alice | 10 |
      """)

    assert %RenderResult{canonical_text: canonical, warnings: warnings} = result
    assert canonical == "| name | score |\n| --- | --- |\n| alice | 10 |"
    assert warnings == [:feishu_table_degraded_to_markdown]
  end

  test "renderer keeps new_message as boundary metadata without rendering separator payload" do
    results = Feishu.render("before<newmsg/>after\n")

    assert Enum.any?(results, &(&1.new_message? and &1.canonical_text == "<newmsg/>"))

    boundary =
      Enum.find(results, fn result ->
        result.new_message?
      end)

    assert boundary.payload == nil
    assert boundary.text == ""
  end
end
