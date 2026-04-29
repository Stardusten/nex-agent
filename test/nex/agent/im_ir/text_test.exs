defmodule Nex.Agent.Interface.IMIR.TextTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Interface.IMIR.Text

  test "chunk_message prefers the boundary before a fenced code block" do
    text = String.duplicate("x", 24) <> "\n\n```text\nhello\n```"

    chunks = Text.chunk_message(text, 32)

    assert length(chunks) == 2
    assert Enum.all?(chunks, &(String.length(&1) <= 32))
    refute Enum.at(chunks, 0) =~ "```"
    assert Enum.at(chunks, 1) == "```text\nhello\n```"
    assert Enum.all?(chunks, &balanced_fences?/1)
  end

  test "chunk_message backs up before the fence opener when overflow is detected after it" do
    text = "xxx\n\n```text\n" <> String.duplicate("a", 24) <> "\n```"

    chunks = Text.chunk_message(text, 18)

    assert hd(chunks) == "xxx"
    assert Enum.all?(tl(chunks), &String.starts_with?(&1, "```text\n"))
    assert Enum.all?(chunks, &(String.length(&1) <= 18))
    assert Enum.all?(chunks, &balanced_fences?/1)
  end

  test "chunk_message balances oversized fenced code blocks" do
    text = "```text\n" <> String.duplicate("a", 72) <> "\n```"

    chunks = Text.chunk_message(text, 36)

    assert length(chunks) > 1
    assert Enum.all?(chunks, &(String.length(&1) <= 36))
    assert Enum.all?(chunks, &String.starts_with?(&1, "```text\n"))
    assert Enum.all?(chunks, &balanced_fences?/1)
  end

  test "split_at_safe_boundary rejects cuts inside fenced code blocks" do
    text = String.duplicate("x", 24) <> "\n\n```text\nhello\n```"

    assert {:ok, first, rest} = Text.split_at_safe_boundary(text, 32)
    refute first =~ "```"
    assert rest == "```text\nhello\n```"
  end

  defp balanced_fences?(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.reduce(false, fn line, in_code? ->
      if line |> String.trim_leading() |> String.starts_with?("```") do
        not in_code?
      else
        in_code?
      end
    end)
    |> Kernel.not()
  end
end
