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

  test "soul_update rejects durable identity definitions in soul", %{workspace: workspace} do
    expected_error =
      "Invalid content (identity_definition_in_soul): SOUL.md contains durable identity definitions; core self-definition belongs to IDENTITY.md."

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

  test "soul_update strips legacy identity footer from rewritten soul", %{workspace: workspace} do
    content = """
    # Soul

    Keep responses concise.

    ---

    *编辑此文件来自定义助手的行为风格和价值观。身份定义由代码层管理，此处不可重新定义。*
    """

    assert {:ok, "SOUL.md updated successfully."} =
             SoulUpdate.execute(%{"content" => content}, %{})

    updated = File.read!(Path.join(workspace, "SOUL.md"))
    assert updated == "# Soul\n\nKeep responses concise.\n"
    refute updated =~ "身份定义由代码层管理"
  end

  test "soul_update still rejects user profile leakage into soul" do
    expected_error =
      "Invalid content (user_profile_data_in_soul): SOUL.md contains user profile data; user profile details belong to USER.md."

    assert {:error, ^expected_error} =
             SoulUpdate.execute(%{"content" => "# Soul\n- **Timezone**: UTC+8\n"}, %{})

    assert File.read!(Path.join(Application.fetch_env!(:nex_agent, :workspace_path), "SOUL.md")) ==
             "# Soul\nStay practical.\n"
  end

  test "soul_update description and contract point identity to IDENTITY" do
    assert SoulUpdate.description() =~ "persona guidance"
    assert SoulUpdate.description() =~ "Durable self-definition belongs in IDENTITY.md"

    soul_layer = LayerContractHelper.matrix()["SOUL"]

    assert soul_layer.allowed ==
             "Behavioral tone, values, voice, and style preferences."

    assert soul_layer.forbidden == [
             "Durable self-definition that belongs in IDENTITY.",
             "User profile details that belong in USER."
           ]

    assert LayerContractHelper.write_policy() =~ "invalid writes are rejected"
  end
end
