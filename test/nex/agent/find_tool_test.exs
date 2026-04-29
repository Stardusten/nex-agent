defmodule Nex.Agent.FindToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Capability.Tool.Core.Find

  test "find returns structured matches and truncation metadata" do
    root = Path.join("/tmp", "nex-agent-find-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/one.ex"), "def alpha do\n  :needle\nend\n")
    File.write!(Path.join(root, "lib/two.ex"), "def beta do\n  :needle\nend\n")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, result} =
             Find.execute(
               %{"query" => "needle", "path" => root, "glob" => "*.ex", "limit" => 1},
               %{}
             )

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

  test "find honors file_access allowed roots from tool context config" do
    previous_allowed_roots = System.get_env("NEX_ALLOWED_ROOTS")
    System.delete_env("NEX_ALLOWED_ROOTS")

    root =
      Path.expand(
        "../#{Path.basename(File.cwd!())}-find-allowed-#{System.unique_integer([:positive])}",
        File.cwd!()
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "external.txt"), "needle\n")

    on_exit(fn ->
      if previous_allowed_roots,
        do: System.put_env("NEX_ALLOWED_ROOTS", previous_allowed_roots),
        else: System.delete_env("NEX_ALLOWED_ROOTS")

      File.rm_rf!(root)
    end)

    assert {:error, message} = Find.execute(%{"query" => "needle", "path" => root}, %{})
    assert message =~ "Path not within allowed roots"

    config = Config.from_map(%{"tools" => %{"file_access" => %{"allowed_roots" => [root]}}})

    assert {:ok, result} = Find.execute(%{"query" => "needle", "path" => root}, %{config: config})
    assert [%{preview: "needle"}] = result.matches
  end
end
