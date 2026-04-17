defmodule Nex.Agent.IMIR.RenderResultTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.IMIR.Block
  alias Nex.Agent.IMIR.RenderResult

  test "from_block preserves frozen render result shape for ordinary blocks" do
    block = %Block{
      type: :paragraph,
      text: "hello",
      canonical_text: "hello",
      complete?: true
    }

    assert %RenderResult{
             payload: ^block,
             text: "hello",
             complete?: true,
             new_message?: false,
             canonical_text: "hello",
             warnings: []
           } = RenderResult.from_block(block)
  end

  test "from_block marks new_message blocks without dropping canonical token" do
    block = %Block{
      type: :new_message,
      text: "",
      canonical_text: "<newmsg/>",
      complete?: true
    }

    assert %RenderResult{
             text: "",
             complete?: true,
             new_message?: true,
             canonical_text: "<newmsg/>"
           } = RenderResult.from_block(block)
  end

  test "from_block allows explicit renderer payload and warnings" do
    block = %Block{
      type: :table,
      text: "|a|b|",
      canonical_text: "|a|b|",
      complete?: true
    }

    result =
      RenderResult.from_block(block,
        payload: %{kind: :table_fragment},
        text: "a | b",
        warnings: [:degraded_table]
      )

    assert result.payload == %{kind: :table_fragment}
    assert result.text == "a | b"
    assert result.complete?
    assert result.canonical_text == "|a|b|"
    assert result.warnings == [:degraded_table]
  end
end
