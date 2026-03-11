defmodule Nex.Agent.Tool.Write do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.HotReload
  alias Nex.Agent.Security

  def name, do: "write"

  def description,
    do: "Write content to a file. Writing .ex files auto-triggers compilation and hot-reload."

  def category, do: :base

  def definition do
    %{
      name: "write",
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to file"},
          content: %{type: "string", description: "Content to write"}
        },
        required: ["path", "content"]
      }
    }
  end

  def execute(%{"path" => path, "content" => content}, _ctx) do
    case Security.validate_path(path) do
      {:ok, expanded} ->
        dir = Path.dirname(expanded)
        File.mkdir_p!(dir)

        case File.write(expanded, content) do
          :ok ->
            if String.ends_with?(expanded, ".ex") do
              hot_reload = auto_reload(expanded, content)
              {:ok, %{path: expanded, hot_reload: hot_reload}}
            else
              {:ok, "File written successfully: #{expanded}"}
            end

          {:error, reason} ->
            {:error, "Error writing file #{expanded}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Security: #{reason}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "path and content are required"}

  defp auto_reload(path, content) do
    HotReload.reload(path, content)
  end
end
