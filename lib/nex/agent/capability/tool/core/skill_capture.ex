defmodule Nex.Agent.Capability.Tool.Core.SkillCapture do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Capability.Skills

  def name, do: "skill_capture"

  def description do
    "Capture a new local Markdown skill in the SKILL layer."
  end

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Workspace skill name"},
          description: %{type: "string", description: "What reusable workflow this captures"},
          content: %{type: "string", description: "Markdown instructions for the skill"}
        },
        required: ["name", "description", "content"]
      }
    }
  end

  def execute(
        %{"name" => _name, "description" => _description, "content" => _content} = args,
        ctx
      ) do
    opts = workspace_opts(ctx)

    with {:ok, skill} <- Skills.create(args, opts) do
      {:ok,
       %{
         "id" => "workspace:#{skill.name}",
         "name" => skill.name,
         "path" => skill.path
       }}
    end
  end

  def execute(_args, _ctx), do: {:error, "name, description, and content are required"}

  defp workspace_opts(%{workspace: workspace}) when is_binary(workspace),
    do: [workspace: workspace]

  defp workspace_opts(_ctx), do: []
end
