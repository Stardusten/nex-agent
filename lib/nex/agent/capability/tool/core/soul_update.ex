defmodule Nex.Agent.Capability.Tool.Core.SoulUpdate do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour
  alias Nex.Agent.Turn.ContextDiagnostics

  @legacy_footers [
    "*编辑此文件来自定义助手的行为风格和价值观。身份定义由代码层管理，此处不可重新定义。*",
    "*Edit this file to customize the agent's behavioral style and values. Identity is code-owned and cannot be redefined here.*"
  ]

  def name, do: "soul_update"

  def description,
    do:
      "Update SOUL.md persona guidance (values, tone, voice, and style). Durable self-definition belongs in IDENTITY.md; user profile data belongs in USER.md."

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

  def execute(%{"content" => content}, ctx) do
    normalized = normalize_legacy_footers(content)
    trimmed = String.trim(normalized)

    if trimmed == "" do
      {:error, "content is required"}
    else
      persist_soul(normalized, ctx)
    end
  end

  def execute(_args, _ctx), do: {:error, "content is required"}

  defp persist_soul(content, ctx) do
    case ContextDiagnostics.validate_write(:soul, content, source: "SOUL.md") do
      {:error, diagnostics} ->
        {:error, ContextDiagnostics.write_error_message(diagnostics)}

      :ok ->
        workspace =
          Map.get(ctx, :workspace) || Map.get(ctx, "workspace") ||
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

  defp normalize_legacy_footers(content) do
    content
    |> to_string()
    |> then(fn text ->
      Enum.reduce(@legacy_footers, text, fn footer, acc -> String.replace(acc, footer, "") end)
    end)
    |> String.replace(~r/\n[ \t]*---[ \t]*\n\s*\z/u, "\n")
    |> String.trim_trailing()
  end
end
