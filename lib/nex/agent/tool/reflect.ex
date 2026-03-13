defmodule Nex.Agent.Tool.Reflect do
  @moduledoc """
  Self-reflection tool - lets the agent read its own source code and version history.
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.CodeUpgrade

  def name, do: "reflect"

  def description,
    do: "Inspect CODE-layer source modules, version history, and diffs before a code upgrade."

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          module: %{type: "string", description: "Module name to inspect (e.g. Nex.Agent.Runner)"},
          action: %{
            type: "string",
            enum: ["source", "versions", "diff", "list_modules"],
            description:
              "source: view current code, versions: list history, diff: compare versions, list_modules: list all upgradable modules"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(%{"action" => "list_modules"}, _ctx) do
    modules =
      CodeUpgrade.list_upgradable_modules()
      |> Enum.reject(&custom_tool_module?/1)

    formatted =
      modules
      |> Enum.map_join("\n", fn m ->
        name = m |> to_string() |> String.replace_prefix("Elixir.", "")
        "- #{name}"
      end)

    {:ok, "Upgradable modules (#{length(modules)}):\n#{formatted}"}
  end

  def execute(%{"action" => "source", "module" => module_str}, _ctx) do
    with :ok <- reject_custom_module(module_str) do
      module = String.to_existing_atom("Elixir.#{module_str}")

      case CodeUpgrade.get_source(module) do
        {:ok, source} -> {:ok, "# #{module_str}\n\n```elixir\n#{source}\n```"}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    ArgumentError -> {:error, "Unknown module: #{module_str}"}
  end

  def execute(%{"action" => "versions", "module" => module_str}, _ctx) do
    with :ok <- reject_custom_module(module_str) do
      module = String.to_existing_atom("Elixir.#{module_str}")

      versions = CodeUpgrade.list_versions(module)

      if versions == [] do
        {:ok, "No evolution history for #{module_str}"}
      else
        formatted =
          Enum.map_join(versions, "\n", fn v ->
            "- #{v.id} (#{v.timestamp})"
          end)

        {:ok, "Versions for #{module_str}:\n#{formatted}"}
      end
    end
  rescue
    ArgumentError -> {:error, "Unknown module: #{module_str}"}
  end

  def execute(%{"action" => "diff", "module" => module_str, "code" => new_code}, _ctx) do
    with :ok <- reject_custom_module(module_str) do
      module = String.to_existing_atom("Elixir.#{module_str}")
      diff = CodeUpgrade.diff(module, new_code)
      {:ok, diff}
    end
  rescue
    ArgumentError -> {:error, "Unknown module: #{module_str}"}
  end

  def execute(%{"action" => "diff"}, _ctx),
    do: {:error, "diff requires module and code parameters"}

  def execute(%{"action" => "source"}, _ctx), do: {:error, "source requires module parameter"}
  def execute(%{"action" => "versions"}, _ctx), do: {:error, "versions requires module parameter"}

  def execute(_args, _ctx),
    do: {:error, "action is required (source, versions, diff, list_modules)"}

  defp reject_custom_module(module_str) do
    if custom_tool_module?(module_str) do
      {:error,
       "reflect is for CODE-layer framework modules. For workspace custom tools, inspect/edit files in workspace/tools."}
    else
      :ok
    end
  end

  defp custom_tool_module?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Nex.Agent.Tool.Custom.")
  end

  defp custom_tool_module?(module_str) when is_binary(module_str) do
    String.starts_with?(module_str, "Nex.Agent.Tool.Custom.")
  end

  defp custom_tool_module?(_), do: false
end
