defmodule Nex.Agent.Capability.Tool.Core.UserUpdate do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Turn.ContextDiagnostics
  alias Nex.Agent.Knowledge.Memory
  alias Nex.Agent.Sandbox.FileSystem

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

    with {:ok, current} <- read_current_profile(workspace, ctx) do
      case action do
        "append" ->
          do_append(current, Map.get(args, "content"), workspace, ctx)

        "set" ->
          do_set(Map.get(args, "content"), workspace, ctx)

        _ ->
          {:error, "Unknown action: #{action}"}
      end
    end
  end

  def execute(_args, _ctx), do: {:error, "action is required"}

  # Private functions for user profile operations

  defp do_append(_current, nil, _workspace, _ctx), do: {:error, "content is required for append"}
  defp do_append(_current, "", _workspace, _ctx), do: {:error, "content is required for append"}

  defp do_append(current, content, workspace, ctx) do
    trimmed = String.trim(content)

    if trimmed == "" do
      {:error, "content is required for append"}
    else
      case ContextDiagnostics.validate_write(:user, trimmed, source: "USER.md") do
        :ok ->
          updated =
            if String.trim(current) == "" do
              "# User Profile\n\n#{trimmed}\n"
            else
              upsert_or_append_profile_line(current, trimmed)
            end

          with :ok <- write_profile(updated, workspace, ctx) do
            {:ok, "User profile updated (appended)."}
          end

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

  defp do_set(nil, _workspace, _ctx), do: {:error, "content is required for set"}
  defp do_set("", _workspace, _ctx), do: {:error, "content is required for set"}

  defp do_set(new_content, workspace, ctx) do
    trimmed = String.trim(new_content)

    if trimmed == "" do
      {:error, "content is required for set"}
    else
      case ContextDiagnostics.validate_write(:user, trimmed, source: "USER.md") do
        :ok ->
          updated = String.trim_trailing(new_content) <> "\n"

          with :ok <- write_profile(updated, workspace, ctx) do
            {:ok, "User profile updated (set)."}
          end

        {:error, diagnostics} ->
          {:error, ContextDiagnostics.write_error_message(diagnostics)}
      end
    end
  end

  defp read_current_profile(workspace, ctx) do
    path = user_profile_path(workspace)
    auth_ctx = put_ctx_workspace(ctx, profile_workspace(workspace))

    with {:ok, info} <- FileSystem.authorize(path, :read, auth_ctx),
         {:ok, exists?} <- FileSystem.exists?(info) do
      if exists? do
        FileSystem.read_file(info)
      else
        {:ok, ""}
      end
    end
  end

  defp write_profile(content, workspace, ctx) do
    path = user_profile_path(workspace)
    auth_ctx = put_ctx_workspace(ctx, profile_workspace(workspace))
    FileSystem.write_file(path, content, auth_ctx)
  end

  defp user_profile_path(workspace), do: Path.join(profile_workspace(workspace), "USER.md")

  defp profile_workspace(workspace) when is_binary(workspace) and workspace != "",
    do: workspace

  defp profile_workspace(_workspace), do: Memory.workspace_path()

  defp put_ctx_workspace(ctx, workspace) when is_map(ctx), do: Map.put(ctx, :workspace, workspace)

  defp put_ctx_workspace(ctx, workspace) when is_list(ctx),
    do: Keyword.put(ctx, :workspace, workspace)

  defp put_ctx_workspace(_ctx, workspace), do: %{workspace: workspace}
end
