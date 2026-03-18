defmodule Nex.Agent.WriteEditToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.{Edit, Write}

  test "write rolls back invalid elixir source when hot reload fails" do
    path = "/tmp/nex-agent-write-invalid-#{System.unique_integer([:positive])}.ex"

    on_exit(fn -> File.rm(path) end)

    assert {:error, reason} =
             Write.execute(
               %{
                 "path" => path,
                 "content" => "defmodule TmpBadWrite do\n  def broken( do\nend\n"
               },
               %{}
             )

    assert reason =~ "Changes reverted"
    refute File.exists?(path)
  end

  test "edit restores previous content when hot reload fails" do
    path = "/tmp/nex-agent-edit-invalid-#{System.unique_integer([:positive])}.ex"

    original = """
    defmodule TmpEditOriginal do
      def ok, do: :ok
    end
    """

    File.write!(path, original)

    on_exit(fn -> File.rm(path) end)

    assert {:error, reason} =
             Edit.execute(
               %{"path" => path, "search" => "def ok, do: :ok", "replace" => "def ok( do"},
               %{}
             )

    assert reason =~ "Changes reverted"
    assert File.read!(path) == original
  end
end
