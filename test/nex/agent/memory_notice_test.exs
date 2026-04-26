defmodule Nex.Agent.MemoryNoticeTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Memory.Notice

  test "render marks truncated summaries with ellipsis" do
    summary = String.duplicate("a", 160)

    assert Notice.summary(summary) == String.duplicate("a", 137) <> "..."
    assert Notice.render(summary) == "🧠 Memory - " <> String.duplicate("a", 137) <> "..."
  end

  test "render leaves short summaries untouched" do
    assert Notice.render("Captured concise reply preference.") ==
             "🧠 Memory - Captured concise reply preference."
  end
end
