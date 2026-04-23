defmodule Nex.Agent.ApplyPatchToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.ApplyPatch

  test "apply_patch updates files with multiple hunks" do
    path = Path.join("/tmp", "nex-agent-apply-patch-#{System.unique_integer([:positive])}.ex")

    File.write!(
      path,
      """
      defmodule TmpPatch do
        def alpha, do: :one
        def beta, do: :two
      end
      """
    )

    on_exit(fn -> File.rm(path) end)

    assert {:ok, result} =
             ApplyPatch.execute(
               %{
                 "patch" => """
                 *** Begin Patch
                 *** Update File: #{path}
                 @@
                  defmodule TmpPatch do
                 -  def alpha, do: :one
                 +  def alpha, do: :uno
                 @@
                 -  def beta, do: :two
                 +  def beta, do: :dos
                  end
                 *** End Patch
                 """
               },
               %{}
             )

    assert result.status == :ok
    assert result.updated_files == [path]
    assert result.created_files == []
    assert result.deleted_files == []
    assert File.read!(path) =~ "def alpha, do: :uno"
    assert File.read!(path) =~ "def beta, do: :dos"
  end

  test "apply_patch can add and delete files" do
    root = Path.join("/tmp", "nex-agent-apply-patch-files-#{System.unique_integer([:positive])}")
    create_path = Path.join(root, "created.txt")
    delete_path = Path.join(root, "delete.txt")

    File.mkdir_p!(root)
    File.write!(delete_path, "delete me\n")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, result} =
             ApplyPatch.execute(
               %{
                 "patch" => """
                 *** Begin Patch
                 *** Add File: #{create_path}
                 +hello
                 +world
                 *** Delete File: #{delete_path}
                 *** End Patch
                 """
               },
               %{}
             )

    assert result.status == :ok
    assert result.created_files == [create_path]
    assert result.deleted_files == [delete_path]
    assert File.read!(create_path) == "hello\nworld\n"
    refute File.exists?(delete_path)
  end

  test "apply_patch rolls back earlier writes when a later hunk fails" do
    root = Path.join("/tmp", "nex-agent-apply-patch-rollback-#{System.unique_integer([:positive])}")
    first_path = Path.join(root, "first.txt")
    second_path = Path.join(root, "second.txt")

    File.mkdir_p!(root)
    File.write!(first_path, "alpha\n")
    File.write!(second_path, "beta\n")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, message} =
             ApplyPatch.execute(
               %{
                 "patch" => """
                 *** Begin Patch
                 *** Update File: #{first_path}
                 @@
                 -alpha
                 +omega
                 *** Update File: #{second_path}
                 @@
                 -missing
                 +gamma
                 *** End Patch
                 """
               },
               %{}
             )

    assert message =~ "Patch context mismatch"
    assert File.read!(first_path) == "alpha\n"
    assert File.read!(second_path) == "beta\n"
  end

  test "apply_patch move cleans up destination when source delete fails" do
    root = Path.join("/tmp", "nex-agent-apply-patch-move-#{System.unique_integer([:positive])}")
    source_dir = Path.join(root, "source")
    destination_dir = Path.join(root, "destination")
    source = Path.join(source_dir, "source.txt")
    destination = Path.join(destination_dir, "moved.txt")

    File.mkdir_p!(source_dir)
    File.mkdir_p!(destination_dir)
    File.write!(source, "hello\n")

    on_exit(fn ->
      File.chmod(source_dir, 0o755)
      File.rm_rf(root)
    end)

    assert :ok = File.chmod(source_dir, 0o555)

    assert {:error, message} =
             ApplyPatch.execute(
               %{
                 "patch" => """
                 *** Begin Patch
                 *** Update File: #{source}
                 *** Move to: #{destination}
                 @@
                 -hello
                 +hello
                 *** End Patch
                 """
               },
               %{}
             )

    assert message =~ "Failed to move"
    assert File.read!(source) == "hello\n"
    refute File.exists?(destination)
  end
end
