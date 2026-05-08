defmodule Nex.Agent.Capability.Tool.Core.ToolList do
  @moduledoc "List built-in and custom tools, and inspect details for one tool."

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Capability.Tool.CustomTools
  alias Nex.Agent.Capability.Tool.Registry

  def name, do: "tool_list"

  def description,
    do: "List built-in and custom tools in the TOOL layer, or inspect a specific tool."

  def category, do: :evolution
  def surfaces, do: [:all, :follow_up]

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          scope: %{
            type: "string",
            enum: ["builtin", "custom", "all"],
            description: "Which tool scope to list",
            default: "all"
          },
          detail: %{type: "string", description: "Tool name to inspect"}
        }
      }
    }
  end

  def execute(%{"detail" => tool_name}, _ctx) when is_binary(tool_name) and tool_name != "" do
    case custom_detail(tool_name) || builtin_detail(tool_name) do
      nil -> {:error, "Tool not found: #{tool_name}"}
      detail -> {:ok, detail}
    end
  end

  def execute(%{"scope" => scope}, _ctx) when scope in ["builtin", "custom", "all"] do
    {:ok,
     %{
       scope: scope,
       builtin: if(scope in ["builtin", "all"], do: builtin_list(), else: []),
       custom: if(scope in ["custom", "all"], do: custom_list(), else: [])
     }}
  end

  def execute(_args, ctx), do: execute(%{"scope" => "all"}, ctx)

  defp builtin_list do
    custom_names = MapSet.new(Enum.map(custom_list(), & &1["name"]))

    Registry.list()
    |> Enum.reject(&MapSet.member?(custom_names, &1))
    |> Enum.sort()
    |> Enum.map(fn name -> Registry.describe(name) |> Map.put("scope", "builtin") end)
  end

  defp custom_list do
    CustomTools.list()
    |> Enum.map(fn tool ->
      %{
        "name" => tool["name"],
        "scope" => tool["scope"],
        "layers" => ["tool"],
        "module" => tool["module"],
        "description" => tool["description"],
        "source_path" => tool.source_path,
        "origin" => tool["origin"]
      }
    end)
  end

  defp builtin_detail(name) do
    custom_names = MapSet.new(Enum.map(custom_list(), & &1["name"]))

    if MapSet.member?(custom_names, name) do
      nil
    else
      Registry.describe(name) |> then(&(&1 && Map.put(&1, "scope", "builtin")))
    end
  end

  defp custom_detail(name) do
    case CustomTools.detail(name) do
      nil ->
        nil

      tool ->
        %{
          "name" => tool["name"],
          "scope" => tool["scope"],
          "layers" => ["tool"],
          "module" => tool["module"],
          "description" => tool["description"],
          "source_path" => tool.source_path,
          "metadata_path" => tool.metadata_path,
          "definition" => tool.definition,
          "created_by" => tool["created_by"],
          "created_at" => tool["created_at"],
          "updated_at" => tool["updated_at"],
          "origin" => tool["origin"]
        }
    end
  end

end
