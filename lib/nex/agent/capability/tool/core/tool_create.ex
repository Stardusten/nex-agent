defmodule Nex.Agent.Capability.Tool.Core.ToolCreate do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Capability.Tool.CustomTools

  def name, do: "tool_create"

  def description,
    do: "Create a new workspace custom Elixir tool in the TOOL layer under workspace/tools."

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Tool name in snake_case"},
          description: %{type: "string", description: "What this tool does"},
          content: %{
            type: "string",
            description:
              "Complete Elixir module source with @behaviour Nex.Agent.Capability.Tool.Behaviour and callbacks name/0, description/0, category/0, definition/0, execute/2"
          },
          parameters: %{type: "object", description: "Reserved for future tool generators"}
        },
        required: ["name", "description", "content"]
      }
    }
  end

  def execute(%{"name" => name, "description" => description, "content" => content}, ctx) do
    created_by =
      Map.get(ctx, :created_by) ||
        Map.get(ctx, "created_by") ||
        "agent"

    case CustomTools.create(name, description, content, created_by: created_by) do
      {:ok, tool} ->
        {:ok,
         %{
           status: "created",
           tool: tool,
           message: "Custom tool '#{name}' created and registered."
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_args, _ctx), do: {:error, "name, description, and content are required"}
end
