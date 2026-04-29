defmodule Nex.Agent.ProfilePathGuardTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Capability.Tool.Core.{ApplyPatch, Read}

  setup do
    workspace = Path.join("/tmp", "nex-agent-profile-guard-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/USER.md"), "shadow")
    Application.put_env(:nex_agent, :workspace_path, workspace)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "read/apply_patch block workspace/memory/USER.md", %{workspace: workspace} do
    shadow_path = Path.join(workspace, "memory/USER.md")

    assert {:error, msg} = Read.execute(%{"path" => shadow_path}, %{})
    assert msg =~ "workspace/USER.md"

    assert {:error, msg} =
             ApplyPatch.execute(
               %{
                 "patch" => """
                 *** Begin Patch
                 *** Update File: #{shadow_path}
                 @@
                 -shadow
                 +x
                 *** End Patch
                 """
               },
               %{}
             )

    assert msg =~ "user_update"
  end
end
