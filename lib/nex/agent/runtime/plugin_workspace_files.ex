defmodule Nex.Agent.Runtime.PluginWorkspaceFiles do
  @moduledoc false

  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Sandbox.{Approval, FileSystem}
  require Log

  @spec ensure_declared!(String.t(), map(), map() | struct() | nil) :: :ok
  def ensure_declared!(workspace, plugins_data, config \\ nil) when is_binary(workspace) do
    workspace_files(plugins_data)
    |> Enum.each(fn entry -> ensure_workspace_file(workspace, entry, config) end)

    :ok
  end

  @spec watch_paths(String.t(), map()) :: [String.t()]
  def watch_paths(workspace, plugins_data) when is_binary(workspace) do
    workspace_files(plugins_data)
    |> Enum.filter(&(get_in(&1, ["attrs", "watch"]) == true))
    |> Enum.flat_map(&validated_watch_path(workspace, &1))
    |> Enum.uniq()
  end

  defp workspace_files(plugins_data) do
    contributions =
      Map.get(plugins_data, :contributions) || Map.get(plugins_data, "contributions") || %{}

    Map.get(contributions, :workspace_files) || Map.get(contributions, "workspace_files") || []
  end

  defp ensure_workspace_file(workspace, %{"attrs" => %{} = attrs} = entry, config) do
    ctx = %{
      workspace: workspace,
      config: config,
      plugin_id: entry["plugin_id"],
      workspace_file_id: entry["id"],
      actor: %{"kind" => "system", "id" => "plugin-workspace-file"}
    }

    case {Map.get(attrs, "onMissing"), Map.get(attrs, "kind", "file"),
          workspace_path(workspace, entry)} do
      {"create", "dir", path} ->
        validate_workspace_path!(workspace, path)
        ensure_directory(path, ctx)

      {"create", _kind, path} ->
        validate_workspace_path!(workspace, path)
        ensure_file(path, ctx)

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

  defp ensure_directory(path, ctx) do
    with {:ok, _info} <- authorize_workspace_write(path, ctx) do
      FileSystem.mkdir_p(path, ctx)
    end
    |> case do
      :ok ->
        :ok

      {:ask, _request} ->
        raise "workspace directory creation requires approval: #{path}"

      {:error, reason} ->
        raise "workspace directory creation failed for #{path}: #{inspect(reason)}"
    end
  end

  defp ensure_file(path, ctx) do
    case authorize_workspace_write(path, ctx) do
      {:ok, info} ->
        unless File.exists?(info.expanded_path) do
          case FileSystem.write_file(info, "", ctx) do
            :ok ->
              :ok

            {:error, reason} ->
              raise "workspace file creation failed for #{path}: #{inspect(reason)}"
          end
        end

        :ok

      {:ask, _request} ->
        raise "workspace file creation requires approval: #{path}"

      {:error, reason} ->
        raise "workspace file creation failed for #{path}: #{inspect(reason)}"
    end
  end

  defp authorize_workspace_write(path, ctx) do
    case permission_rule_decision(path, ctx) do
      :deny ->
        {:error, "workspace file creation denied by permission rule: #{path}"}

      _ ->
        FileSystem.authorize(path, :write, ctx)
    end
  end

  defp permission_rule_decision(path, %{workspace: workspace} = ctx) when is_binary(workspace) do
    with pid when is_pid(pid) <- Process.whereis(Approval) do
      raw_event = path_permission_event(path, ctx)

      case Approval.debug_decision(workspace, session_key(ctx), raw_event,
             extra_rules: config_default_path_rules(Map.get(ctx, :config), workspace)
           ) do
        %{action: action} -> action
        _ -> :ask
      end
    else
      _ -> :ask
    end
  end

  defp permission_rule_decision(_path, _ctx), do: :ask

  defp path_permission_event(path, ctx) do
    %{
      tool_name: "filesystem",
      params: %{"path" => path, "operation" => "write"},
      workspace: Map.get(ctx, :workspace),
      actor: Map.get(ctx, :actor),
      metadata: %{
        "plugin_id" => Map.get(ctx, :plugin_id),
        "workspace_file_id" => Map.get(ctx, :workspace_file_id)
      }
    }
  end

  defp config_default_path_rules(%Config{} = config, workspace) do
    raw = Config.sandbox_runtime(config, workspace: workspace).raw || %{}
    approval = Map.get(raw, "approval") || %{}

    case Map.get(approval, "default") do
      "allow" ->
        [
          %{
            id: "config_default_allow_workspace_file",
            level: 0,
            effect: :allow,
            scope: :workspace,
            source: :workspace_config,
            predicates: [{:resource_eq, :path}, {:operation_in, [:write]}]
          }
        ]

      _ ->
        []
    end
  end

  defp config_default_path_rules(_config, _workspace), do: []

  defp session_key(ctx), do: "plugin:" <> to_string(Map.get(ctx, :plugin_id) || "workspace_files")

  defp validate_workspace_path!(workspace, path) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(path)

    if expanded_path == expanded_workspace or
         String.starts_with?(expanded_path, expanded_workspace <> "/") do
      :ok
    else
      raise ArgumentError, "workspace file path escapes workspace: #{expanded_path}"
    end
  end

  defp workspace_path(workspace, %{"attrs" => %{"path" => path}}) do
    Path.expand(to_string(path), workspace)
  end

  defp validated_watch_path(workspace, entry) do
    path = workspace_path(workspace, entry)
    validate_workspace_path!(workspace, path)
    [path]
  rescue
    e ->
      Log.warning(
        "plugin.workspace_file.watch_path.invalid",
        %{
          "plugin_id" => entry["plugin_id"],
          "contribution_id" => entry["id"],
          "error_summary" => Exception.message(e)
        },
        workspace: workspace
      )

      []
  end
end
