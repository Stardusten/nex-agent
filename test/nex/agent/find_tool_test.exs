defmodule Nex.Agent.FindToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.Find

  test "find returns structured matches and truncation metadata" do
    root = Path.join("/tmp", "nex-agent-find-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/one.ex"), "def alpha do\n  :needle\nend\n")
    File.write!(Path.join(root, "lib/two.ex"), "def beta do\n  :needle\nend\n")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, result} =
             Find.execute(%{"query" => "needle", "path" => root, "glob" => "*.ex", "limit" => 1}, %{})

    assert result.status == :ok
    assert result.query == "needle"
    assert result.truncated == true
    assert length(result.matches) == 1

    match = hd(result.matches)
    assert String.ends_with?(match.path, ".ex")
    assert match.line == 2
    assert is_integer(match.column)
    assert match.preview =~ "needle"
  end
end
