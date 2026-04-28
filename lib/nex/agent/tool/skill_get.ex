defmodule Nex.Agent.Tool.SkillGet do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Skills

  def name, do: "skill_get"

  def description,
    do: "Load a builtin, workspace, or project skill by id with progressive disclosure."

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          id: %{
            type: "string",
            description:
              "Skill id from the Available Skills catalog, for example builtin:workbench-app-authoring"
          }
        },
        required: ["id"]
      }
    }
  end

  def execute(%{"id" => id}, ctx) when is_binary(id) do
    with {:ok, card} <- Skills.resolve_catalog_skill(id, runtime_opts(ctx)),
         {:ok, payload} <- Skills.read_catalog_skill(card) do
      {:ok, payload}
    end
  end

  def execute(%{id: id}, ctx) when is_binary(id), do: execute(%{"id" => id}, ctx)
  def execute(_args, _ctx), do: {:error, "id is required"}

  defp runtime_opts(ctx) do
    snapshot = Map.get(ctx, :runtime_snapshot)
    catalog_cards = if snapshot, do: get_in(snapshot.skills, [:cards]), else: nil

    [
      workspace: Map.get(ctx, :workspace),
      project_root: Map.get(ctx, :cwd, File.cwd!()),
      catalog_cards: catalog_cards
    ]
  end
end
