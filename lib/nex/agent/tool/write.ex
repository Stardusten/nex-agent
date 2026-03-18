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
        if reserved_profile_shadow_path?(expanded) do
          {:error,
           "USER profile must be managed via user_update and stored at workspace/USER.md, not workspace/memory/USER.md"}
        else
          if String.ends_with?(expanded, ".ex") do
            write_elixir_file(expanded, content)
          else
            write_plain_file(expanded, content)
          end
        end

      {:error, reason} ->
        {:error, "Security: #{reason}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "path and content are required"}

  defp reserved_profile_shadow_path?(expanded) do
    Enum.take(Path.split(expanded), -2) == ["memory", "USER.md"]
  end

  defp write_plain_file(expanded, content) do
    dir = Path.dirname(expanded)
    File.mkdir_p!(dir)

    case File.write(expanded, content) do
      :ok -> {:ok, "File written successfully: #{expanded}"}
      {:error, reason} -> {:error, "Error writing file #{expanded}: #{inspect(reason)}"}
    end
  end

  defp write_elixir_file(expanded, content) do
    dir = Path.dirname(expanded)
    File.mkdir_p!(dir)

    original =
      case File.read(expanded) do
        {:ok, existing} -> {:existing, existing}
        {:error, :enoent} -> :missing
        {:error, reason} -> {:read_error, reason}
      end

    case original do
      {:read_error, reason} ->
        {:error, "Error reading file #{expanded}: #{inspect(reason)}"}

      _ ->
        case File.write(expanded, content) do
          :ok ->
            hot_reload = auto_reload(expanded, content)

            if hot_reload.reload_succeeded do
              {:ok, %{path: expanded, hot_reload: hot_reload}}
            else
              restore_original_file(expanded, original)

              {:error,
               "Hot reload failed for #{expanded}: #{hot_reload.reason}. Changes reverted."}
            end

          {:error, reason} ->
            {:error, "Error writing file #{expanded}: #{inspect(reason)}"}
        end
    end
  end

  defp restore_original_file(path, {:existing, content}), do: File.write(path, content)
  defp restore_original_file(path, :missing), do: File.rm(path)
  defp restore_original_file(_path, {:read_error, _reason}), do: :ok

  defp auto_reload(path, content) do
    HotReload.reload(path, content)
  end
end
