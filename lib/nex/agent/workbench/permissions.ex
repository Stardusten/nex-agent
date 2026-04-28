defmodule Nex.Agent.Workbench.Permissions do
  @moduledoc """
  Owner-approved Workbench app permission grants.
  """

  alias Nex.Agent.ControlPlane.Log
  alias Nex.Agent.Workbench.{AppManifest, Store}
  alias Nex.Agent.Workspace
  require Log

  @store_version 1
  @file_name "permissions.json"

  @type app_view :: %{
          required(String.t()) => term()
        }

  @spec path(keyword()) :: String.t()
  def path(opts \\ []) do
    Path.join(Workspace.workbench_dir(opts), @file_name)
  end

  @spec list(keyword()) :: map()
  def list(opts \\ []) do
    case read_store(opts) do
      {:ok, grants} ->
        apps =
          opts
          |> Store.list()
          |> Enum.map(&app_view(&1, grants))

        %{"apps" => apps, "diagnostics" => []}

      {:error, reason} ->
        %{
          "apps" => [],
          "diagnostics" => [
            %{"path" => path(opts), "error" => "failed to read permissions: #{reason}"}
          ]
        }
    end
  end

  @spec app(String.t(), keyword()) :: {:ok, app_view()} | {:error, String.t()}
  def app(app_id, opts \\ []) when is_binary(app_id) do
    with {:ok, manifest} <- Store.get(app_id, opts),
         {:ok, grants} <- read_store(opts) do
      {:ok, app_view(manifest, grants)}
    end
  end

  @spec grant(String.t(), term(), keyword()) :: {:ok, app_view()} | {:error, String.t()}
  def grant(app_id, permission, opts \\ []) when is_binary(app_id) do
    with {:ok, permission} <- AppManifest.normalize_permission(permission),
         {:ok, manifest} <- Store.get(app_id, opts),
         :ok <- ensure_declared(manifest, permission),
         {:ok, grants} <- read_store(opts),
         updated = put_grant(grants, app_id, permission),
         :ok <- write_store(updated, opts) do
      _ =
        Log.info(
          "workbench.permission.granted",
          %{"app_id" => app_id, "permission" => permission},
          opts
        )

      {:ok, app_view(manifest, updated)}
    end
  end

  @spec revoke(String.t(), term(), keyword()) :: {:ok, app_view()} | {:error, String.t()}
  def revoke(app_id, permission, opts \\ []) when is_binary(app_id) do
    with {:ok, permission} <- AppManifest.normalize_permission(permission),
         {:ok, manifest} <- Store.get(app_id, opts),
         {:ok, grants} <- read_store(opts),
         updated = drop_grant(grants, app_id, permission),
         :ok <- write_store(updated, opts) do
      {:ok, app_view(manifest, updated)}
    end
  end

  @spec check(String.t(), term(), keyword()) :: :ok | {:error, String.t()}
  def check(app_id, permission, opts \\ []) when is_binary(app_id) do
    result =
      with {:ok, permission} <- AppManifest.normalize_permission(permission),
           {:ok, manifest} <- Store.get(app_id, opts),
           :ok <- ensure_declared(manifest, permission),
           {:ok, grants} <- read_store(opts),
           :ok <- ensure_granted(grants, app_id, permission) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ =
          Log.warning(
            "workbench.permission.denied",
            %{
              "app_id" => app_id,
              "permission" => permission_label(permission),
              "reason" => reason
            },
            opts
          )

        {:error, reason}
    end
  end

  defp app_view(%AppManifest{} = manifest, grants) do
    declared = manifest.permissions
    stored_grants = granted_permissions(grants, manifest.id)
    granted = Enum.filter(stored_grants, &(&1 in declared))

    %{
      "app_id" => manifest.id,
      "declared_permissions" => declared,
      "granted_permissions" => granted,
      "stale_granted_permissions" => stored_grants -- declared,
      "denied_permissions" => declared -- granted
    }
  end

  defp ensure_declared(%AppManifest{} = manifest, permission) do
    if permission in manifest.permissions do
      :ok
    else
      {:error, "permission is not declared by app manifest"}
    end
  end

  defp ensure_granted(grants, app_id, permission) do
    if permission in granted_permissions(grants, app_id) do
      :ok
    else
      {:error, "permission is not granted"}
    end
  end

  defp put_grant(grants, app_id, permission) do
    update_app_grants(grants, app_id, fn permissions ->
      [permission | permissions]
      |> Enum.uniq()
      |> Enum.sort()
    end)
  end

  defp drop_grant(grants, app_id, permission) do
    update_app_grants(grants, app_id, fn permissions ->
      permissions
      |> Enum.reject(&(&1 == permission))
      |> Enum.sort()
    end)
  end

  defp update_app_grants(grants, app_id, fun) do
    apps = Map.get(grants, "apps", %{})
    current = app_grants(apps, app_id)

    updated_app = %{
      "permissions" => fun.(current),
      "updated_at" => timestamp()
    }

    grants
    |> Map.put("version", @store_version)
    |> Map.put("apps", Map.put(apps, app_id, updated_app))
  end

  defp granted_permissions(grants, app_id) do
    grants
    |> Map.get("apps", %{})
    |> app_grants(app_id)
  end

  defp app_grants(apps, app_id) when is_map(apps) do
    apps
    |> Map.get(app_id, %{})
    |> Map.get("permissions", [])
    |> normalize_permission_list()
  end

  defp app_grants(_apps, _app_id), do: []

  defp read_store(opts) do
    case File.read(path(opts)) do
      {:ok, body} ->
        with {:ok, decoded} <- Jason.decode(body),
             {:ok, normalized} <- normalize_store(decoded) do
          {:ok, normalized}
        else
          {:error, %Jason.DecodeError{} = error} ->
            {:error, "invalid JSON: #{Exception.message(error)}"}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, empty_store()}

      {:error, reason} ->
        {:error, :file.format_error(reason) |> to_string()}
    end
  end

  defp write_store(grants, opts) do
    target = path(opts)
    tmp = target <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    content = Jason.encode!(normalize_store!(grants), pretty: true) <> "\n"

    result =
      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(tmp, content),
           :ok <- File.rename(tmp, target) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, "failed to write permissions: #{:file.format_error(reason)}"}
    end
  end

  defp normalize_store(store) when is_map(store) do
    store = stringify_keys(store)
    apps = Map.get(store, "apps", %{})

    if is_map(apps) do
      {:ok,
       %{
         "version" => @store_version,
         "apps" =>
           apps
           |> Enum.map(fn {app_id, grant} -> {app_id, normalize_grant(grant)} end)
           |> Map.new()
       }}
    else
      {:error, "apps must be an object"}
    end
  end

  defp normalize_store(_store), do: {:error, "permissions store must be an object"}

  defp normalize_store!(store) do
    case normalize_store(store) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp normalize_grant(grant) when is_map(grant) do
    grant = stringify_keys(grant)

    %{
      "permissions" => normalize_permission_list(Map.get(grant, "permissions", [])),
      "updated_at" => normalize_updated_at(Map.get(grant, "updated_at"))
    }
  end

  defp normalize_grant(_grant), do: %{"permissions" => [], "updated_at" => timestamp()}

  defp normalize_permission_list(list) when is_list(list) do
    list
    |> Enum.flat_map(fn permission ->
      case AppManifest.normalize_permission(permission) do
        {:ok, normalized} -> [normalized]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_permission_list(_list), do: []

  defp normalize_updated_at(value) when is_binary(value) and value != "", do: value
  defp normalize_updated_at(_value), do: timestamp()

  defp empty_store, do: %{"version" => @store_version, "apps" => %{}}

  defp permission_label(permission) when is_binary(permission), do: permission
  defp permission_label(permission), do: inspect(permission, limit: 20, printable_limit: 120)

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
