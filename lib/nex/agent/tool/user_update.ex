defmodule Nex.Agent.Tool.UserUpdate do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.ContextDiagnostics
  alias Nex.Agent.Memory

  def name, do: "user_update"

  def description do
    """
    Update the USER.md profile file in the workspace root.

    Use this to persist stable information about the user:
    - Name, timezone, preferred language
    - Communication style preferences
    - Role and work context
    - Collaboration preferences for working with the user

    Do not use this to set agent identity or persona instructions.

    Use `action=append` for incremental profile updates and `action=set` for full profile regeneration.
    This file is loaded into every session to personalize interactions.
    """
  end

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["append", "set"],
            description: "How to update the profile"
          },
          content: %{
            type: "string",
            description: "New profile content for append/set operations"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(%{"action" => action} = args, ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")

    # Read current USER.md content
    current = Memory.read_user_profile(workspace: workspace)

    case action do
      "append" ->
        do_append(current, Map.get(args, "content"), workspace)

      "set" ->
        do_set(Map.get(args, "content"), workspace)

      _ ->
        {:error, "Unknown action: #{action}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "action is required"}

  # Private functions for user profile operations

  defp do_append(_current, nil, _workspace), do: {:error, "content is required for append"}
  defp do_append(_current, "", _workspace), do: {:error, "content is required for append"}

  defp do_append(current, content, workspace) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        {:error, "content is required for append"}

      true ->
        case ContextDiagnostics.validate_write(:user, trimmed, source: "USER.md") do
          :ok ->
            updated =
              cond do
                String.trim(current) == "" ->
                  "# User Profile\n\n#{trimmed}\n"

                true ->
                  upsert_or_append_profile_line(current, trimmed)
              end

            Memory.write_user_profile(updated, workspace: workspace)
            {:ok, "User profile updated (appended)."}

          {:error, diagnostics} ->
            {:error, ContextDiagnostics.write_error_message(diagnostics)}
        end
    end
  end

  defp upsert_or_append_profile_line(current, new_line) do
    case profile_field_key(new_line) do
      {:ok, key} ->
        pattern = ~r/^- \*\*#{Regex.escape(key)}\*\*:\s?.*$/m

        if Regex.match?(pattern, current) do
          Regex.replace(pattern, current, new_line, global: false)
        else
          String.trim_trailing(current) <> "\n\n" <> new_line <> "\n"
        end

      :error ->
        if String.contains?(current, new_line) do
          current
        else
          String.trim_trailing(current) <> "\n\n" <> new_line <> "\n"
        end
    end
  end

  defp profile_field_key(line) do
    case Regex.named_captures(~r/^- \*\*(?<key>[^*]+)\*\*:\s?.*$/, line) do
      %{"key" => key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> :error
    end
  end

  defp do_set(nil, _workspace), do: {:error, "content is required for set"}
  defp do_set("", _workspace), do: {:error, "content is required for set"}

  defp do_set(new_content, workspace) do
    trimmed = String.trim(new_content)

    cond do
      trimmed == "" ->
        {:error, "content is required for set"}

      true ->
        case ContextDiagnostics.validate_write(:user, trimmed, source: "USER.md") do
          :ok ->
            updated = String.trim_trailing(new_content) <> "\n"
            Memory.write_user_profile(updated, workspace: workspace)
            {:ok, "User profile updated (set)."}

          {:error, diagnostics} ->
            {:error, ContextDiagnostics.write_error_message(diagnostics)}
        end
    end
  end
end
