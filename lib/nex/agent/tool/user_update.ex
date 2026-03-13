defmodule Nex.Agent.Tool.UserUpdate do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Memory

  def name, do: "user_update"

  def description do
    """
    Update the USER.md profile file in the workspace root.

    Use this to persist stable information about the user:
    - Name, timezone, preferred language
    - Communication style preferences
    - Role and work context
    - Any specific instructions for how you should behave

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
            enum: ["add", "replace", "remove"],
            description: "How to update the profile"
          },
          content: %{
            type: "string",
            description: "New content for add/replace operations"
          },
          old_text: %{
            type: "string",
            description: "Exact text to replace or remove (required for replace/remove)"
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
      "add" ->
        do_add(current, Map.get(args, "content"), workspace)

      "replace" ->
        do_replace(current, Map.get(args, "old_text"), Map.get(args, "content"), workspace)

      "remove" ->
        do_remove(current, Map.get(args, "old_text"), workspace)

      _ ->
        {:error, "Unknown action: #{action}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "action is required"}

  # Private functions for user profile operations

  defp do_add(_current, nil, _workspace), do: {:error, "content is required for add"}
  defp do_add(_current, "", _workspace), do: {:error, "content is required for add"}

  defp do_add(current, content, workspace) do
    trimmed = String.trim(content)

    if trimmed == "" do
      {:error, "content is required for add"}
    else
      updated =
        if String.trim(current) == "" do
          "# User Profile\n\n#{trimmed}\n"
        else
          String.trim_trailing(current) <> "\n\n" <> trimmed <> "\n"
        end

      Memory.write_user_profile(updated, workspace: workspace)
      {:ok, "User profile updated (added)."}
    end
  end

  defp do_replace(_current, nil, _content, _workspace),
    do: {:error, "old_text is required for replace"}

  defp do_replace(_current, "", _content, _workspace),
    do: {:error, "old_text is required for replace"}

  defp do_replace(_current, _old_text, nil, _workspace),
    do: {:error, "content is required for replace"}

  defp do_replace(_current, _old_text, "", _workspace),
    do: {:error, "content is required for replace"}

  defp do_replace(current, old_text, new_content, workspace) do
    case String.split(current, old_text, parts: 2) do
      [prefix, suffix] when suffix != current ->
        updated = prefix <> new_content <> suffix
        Memory.write_user_profile(updated, workspace: workspace)
        {:ok, "User profile updated (replaced)."}

      _ ->
        {:error, "old_text not found in user profile"}
    end
  end

  defp do_remove(_current, nil, _workspace), do: {:error, "old_text is required for remove"}
  defp do_remove(_current, "", _workspace), do: {:error, "old_text is required for remove"}

  defp do_remove(current, old_text, workspace) do
    case String.split(current, old_text, parts: 2) do
      [prefix, suffix] when suffix != current ->
        updated =
          (prefix <> suffix)
          |> String.replace(~r/\n{3,}/, "\n\n")
          |> String.trim_trailing()
          |> Kernel.<>("\n")

        Memory.write_user_profile(updated, workspace: workspace)
        {:ok, "User profile updated (removed)."}

      _ ->
        {:error, "old_text not found in user profile"}
    end
  end
end
