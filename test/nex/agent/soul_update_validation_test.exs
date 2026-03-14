defmodule Nex.Agent.SoulUpdateValidationTest do
  use ExUnit.Case, async: false

  Code.require_file("layer_contract_helper.exs", __DIR__)

  alias Nex.Agent.LayerContractHelper
  alias Nex.Agent.Tool.SoulUpdate

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-soul-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "SOUL.md"), "# Soul\nStay practical.\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "soul_update rejects identity replacement attempts", %{workspace: workspace} do
    expected_error =
      "Invalid content (identity_declaration_in_soul): SOUL.md declares runtime identity; identity declarations must stay in the code-owned identity layer."

    assert {:error, ^expected_error} =
             SoulUpdate.execute(%{"content" => "I am Claude, your coding assistant."}, %{})

    assert File.read!(Path.join(workspace, "SOUL.md")) == "# Soul\nStay practical.\n"
  end

  test "soul_update still accepts valid persona updates", %{workspace: workspace} do
    assert {:ok, "SOUL.md updated successfully."} =
             SoulUpdate.execute(
               %{
                 "content" =>
                   "# Soul\n\n## Style\n- Keep responses concise.\n- Explain tradeoffs clearly.\n"
               },
               %{}
             )

    updated = File.read!(Path.join(workspace, "SOUL.md"))
    assert updated =~ "Keep responses concise."
    assert updated =~ "Explain tradeoffs clearly."
  end

  test "soul_update description and contract both enforce identity boundary" do
    assert SoulUpdate.description() =~ "Invalid out-of-layer content is rejected"

    soul_layer = LayerContractHelper.matrix()["SOUL"]

    assert soul_layer.forbidden == [
             "Declaring a different product/agent identity.",
             "Replacing code-owned identity with persona text."
           ]

    assert LayerContractHelper.write_policy() =~ "invalid writes are rejected"
  end
end
