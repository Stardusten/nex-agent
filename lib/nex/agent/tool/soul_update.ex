defmodule Nex.Agent.Tool.SoulUpdate do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour
  alias Nex.Agent.ContextDiagnostics

  def name, do: "soul_update"

  def description,
    do:
      "Update SOUL.md persona guidance (values, tone, and style). Invalid out-of-layer content is rejected."

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          content: %{type: "string", description: "New full content for SOUL.md"}
        },
        required: ["content"]
      }
    }
  end

  def execute(%{"content" => content}, _ctx) do
    trimmed = String.trim(content)

    if trimmed == "" do
      {:error, "content is required"}
    else
      persist_soul(content)
    end
  end

  def execute(_args, _ctx), do: {:error, "content is required"}

  defp persist_soul(content) do
    case ContextDiagnostics.validate_write(:soul, content, source: "SOUL.md") do
      {:error, diagnostics} ->
        {:error, ContextDiagnostics.write_error_message(diagnostics)}

      :ok ->
        workspace =
          Application.get_env(
            :nex_agent,
            :workspace_path,
            Path.join(System.get_env("HOME", "."), ".nex/agent/workspace")
          )

        soul_path = Path.join(workspace, "SOUL.md")

        dir = Path.dirname(soul_path)
        File.mkdir_p!(dir)

        case File.write(soul_path, String.trim_trailing(content) <> "\n") do
          :ok -> {:ok, "SOUL.md updated successfully."}
          {:error, reason} -> {:error, "Error updating SOUL.md: #{inspect(reason)}"}
        end
    end
  end
end
