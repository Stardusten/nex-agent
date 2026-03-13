defmodule Nex.Agent.UserUpdateTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Memory
  alias Nex.Agent.Tool.UserUpdate

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-user-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "USER.md"), "# User Profile\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "user_update writes USER.md", %{workspace: workspace} do
    assert {:ok, _} =
             UserUpdate.execute(
               %{
                 "action" => "add",
                 "content" => "Prefers concise Chinese responses."
               },
               %{workspace: workspace}
             )

    assert Memory.read_user_profile(workspace: workspace) =~ "Prefers concise Chinese responses."
  end

  test "user_update replace and remove work", %{workspace: workspace} do
    :ok =
      Memory.write_user_profile("Name: fenix\nTimezone: Asia/Shanghai\n", workspace: workspace)

    assert {:ok, _} =
             UserUpdate.execute(
               %{
                 "action" => "replace",
                 "old_text" => "Asia/Shanghai",
                 "content" => "UTC+8"
               },
               %{workspace: workspace}
             )

    assert Memory.read_user_profile(workspace: workspace) =~ "UTC+8"

    assert {:ok, _} =
             UserUpdate.execute(
               %{
                 "action" => "remove",
                 "old_text" => "Name: fenix"
               },
               %{workspace: workspace}
             )

    refute Memory.read_user_profile(workspace: workspace) =~ "Name: fenix"
  end
end
