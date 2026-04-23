defmodule Nex.Agent.ReadToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.Read

  test "read returns structured file pagination metadata" do
    path = Path.join("/tmp", "nex-agent-read-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "one\ntwo\nthree\nfour\nfive\n")

    on_exit(fn -> File.rm(path) end)

    assert {:ok, result} =
             Read.execute(
               %{"path" => path, "start_line" => 2, "line_count" => 2, "include_stat" => true},
               %{}
             )

    assert result.status == :ok
    assert result.path == path
    assert result.kind == :file
    assert result.content == "two\nthree"
    assert result.total_lines == 5
    assert result.truncated == true
    assert result.has_more == true
    assert result.next_start_line == 4
    assert result.entries == nil
    assert result.stat.size > 0
  end

  test "read lists directories with stable entries and continuation metadata" do
    root = Path.join("/tmp", "nex-agent-read-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "alpha"))
    File.mkdir_p!(Path.join(root, "beta"))
    File.write!(Path.join(root, "alpha/a.txt"), "a\n")
    File.write!(Path.join(root, "beta/b.txt"), "b\n")
    File.write!(Path.join(root, "root.txt"), "root\n")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, result} =
             Read.execute(
               %{
                 "path" => root,
                 "directory" => %{"depth" => 1, "limit" => 3},
                 "include_stat" => true
               },
               %{}
             )

    assert result.status == :ok
    assert result.kind == :directory
    assert result.content == nil
    assert result.total_lines == 5
    assert result.next_start_line == 4
    assert result.truncated == true
    assert result.has_more == true
    assert Enum.map(result.entries, & &1.path) == ["alpha", "alpha/a.txt", "beta"]
    assert Enum.all?(result.entries, &Map.has_key?(&1, :kind))
    assert Enum.all?(result.entries, &Map.has_key?(&1, :mtime))
  end

  test "read can continue truncated directory listings with start_line" do
    root = Path.join("/tmp", "nex-agent-read-dir-page-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "a\n")
    File.write!(Path.join(root, "b.txt"), "b\n")
    File.write!(Path.join(root, "c.txt"), "c\n")
    File.write!(Path.join(root, "d.txt"), "d\n")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, first_page} =
             Read.execute(%{"path" => root, "directory" => %{"limit" => 2}}, %{})

    assert first_page.entries |> Enum.map(& &1.path) == ["a.txt", "b.txt"]
    assert first_page.next_start_line == 3
    assert first_page.has_more == true

    assert {:ok, second_page} =
             Read.execute(
               %{"path" => root, "directory" => %{"limit" => 2}, "start_line" => first_page.next_start_line},
               %{}
             )

    assert second_page.entries |> Enum.map(& &1.path) == ["c.txt", "d.txt"]
    assert second_page.has_more == false
    assert second_page.next_start_line == nil
  end
end
