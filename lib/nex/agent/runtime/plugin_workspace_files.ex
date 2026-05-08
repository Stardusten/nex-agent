defmodule Nex.Agent.Runtime.PluginWorkspaceFiles do
  @moduledoc false

  alias Nex.Agent.Observe.ControlPlane.Log
  require Log

  @spec ensure_declared!(String.t(), map()) :: :ok
  def ensure_declared!(workspace, plugins_data) when is_binary(workspace) do
    workspace_files(plugins_data)
    |> Enum.each(fn entry -> ensure_workspace_file(workspace, entry) end)

    :ok
  end

  @spec watch_paths(String.t(), map()) :: [String.t()]
  def watch_paths(workspace, plugins_data) when is_binary(workspace) do
    workspace_files(plugins_data)
    |> Enum.filter(&(get_in(&1, ["attrs", "watch"]) == true))
    |> Enum.map(&workspace_path(workspace, &1))
    |> Enum.uniq()
  end

  defp workspace_files(plugins_data) do
    contributions = Map.get(plugins_data, :contributions) || Map.get(plugins_data, "contributions") || %{}
    Map.get(contributions, :workspace_files) || Map.get(contributions, "workspace_files") || []
  end

  defp ensure_workspace_file(workspace, %{"attrs" => %{} = attrs} = entry) do
    case {Map.get(attrs, "onMissing"), Map.get(attrs, "kind", "file"), workspace_path(workspace, entry)} do
      {"create", "dir", path} ->
        validate_workspace_path!(workspace, path)
        File.mkdir_p!(path)

      {"create", _kind, path} ->
        validate_workspace_path!(workspace, path)
        File.mkdir_p!(Path.dirname(path))

        unless File.exists?(path) do
          File.write!(path, "")
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Log.warning(
        "plugin.workspace_file.ensure.failed",
        %{
          "plugin_id" => entry["plugin_id"],
          "contribution_id" => entry["id"],
          "error_summary" => Exception.message(e)
        },
        workspace: workspace
      )
    :ok
  end

  defp validate_workspace_path!(workspace, path) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(path)

    if expanded_path == expanded_workspace or String.starts_with?(expanded_path, expanded_workspace <> "/") do
      :ok
    else
      raise ArgumentError, "workspace file path escapes workspace: #{expanded_path}"
    end
  end

  defp workspace_path(workspace, %{"attrs" => %{"path" => path}}) do
    Path.expand(to_string(path), workspace)
  end
end
