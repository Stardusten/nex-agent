defmodule Nex.Agent.MemoryWriteTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Memory
  alias Nex.Agent.Tool.MemoryWrite

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-memory-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Long-term Memory\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "memory_write writes MEMORY.md", %{workspace: workspace} do
    assert {:ok, _} =
             MemoryWrite.execute(
               %{
                 "action" => "add",
                 "content" => "Project uses OTP supervision."
               },
               %{workspace: workspace}
             )

    assert Memory.read_long_term(workspace: workspace) =~ "Project uses OTP supervision."
  end

  test "memory_write replace and remove work", %{workspace: workspace} do
    :ok =
      Memory.write_long_term("# Long-term Memory\n\nTech stack: Elixir/OTP\n",
        workspace: workspace
      )

    assert {:ok, _} =
             MemoryWrite.execute(
               %{
                 "action" => "replace",
                 "old_text" => "Elixir/OTP",
                 "content" => "Elixir/OTP with Phoenix"
               },
               %{workspace: workspace}
             )

    assert Memory.read_long_term(workspace: workspace) =~ "Phoenix"

    assert {:ok, _} =
             MemoryWrite.execute(
               %{
                 "action" => "remove",
                 "old_text" => "Tech stack: Elixir/OTP with Phoenix\n"
               },
               %{workspace: workspace}
             )

    refute Memory.read_long_term(workspace: workspace) =~ "Tech stack"
  end
end
