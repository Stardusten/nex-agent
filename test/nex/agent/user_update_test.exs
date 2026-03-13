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
                 "action" => "append",
                 "content" => "Prefers concise Chinese responses."
               },
               %{workspace: workspace}
             )

    assert Memory.read_user_profile(workspace: workspace) =~ "Prefers concise Chinese responses."
  end

  test "user_update add upserts an existing profile field instead of duplicating", %{
    workspace: workspace
  } do
    :ok =
      Memory.write_user_profile(
        "# User Profile\n\n## Basic Information\n\n- **Name**: (user's name)\n",
        workspace: workspace
      )

    assert {:ok, _} =
             UserUpdate.execute(
               %{
                 "action" => "append",
                 "content" => "- **Name**: fenix"
               },
               %{workspace: workspace}
             )

    profile = Memory.read_user_profile(workspace: workspace)
    assert profile =~ "- **Name**: fenix"
    refute profile =~ "(user's name)"
    assert length(Regex.scan(~r/^- \*\*Name\*\*:/m, profile)) == 1
  end

  test "user_update set replaces profile", %{workspace: workspace} do
    :ok =
      Memory.write_user_profile("Name: fenix\nTimezone: Asia/Shanghai\n", workspace: workspace)

    assert {:ok, _} =
             UserUpdate.execute(
               %{
                 "action" => "set",
                 "content" =>
                   "# User Profile\n\n## Basic Information\n\n- **Name**: fenix\n- **Timezone**: UTC+8\n"
               },
               %{workspace: workspace}
             )

    profile = Memory.read_user_profile(workspace: workspace)
    assert profile =~ "- **Name**: fenix"
    assert profile =~ "- **Timezone**: UTC+8"
  end
end
