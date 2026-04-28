defmodule Nex.Agent.Workbench.Store do
  @moduledoc """
  File-backed Workbench app manifest store.
  """

  alias Nex.Agent.Workbench.AppManifest
  alias Nex.Agent.Workspace

  @manifest_file "nex.app.json"
  @diagnostic_limit 500

  @type diagnostic :: map()

  @spec apps_dir(keyword()) :: String.t()
  def apps_dir(opts \\ []) do
    Path.join(Workspace.workbench_dir(opts), "apps")
  end

  @spec manifest_path(String.t(), keyword()) :: String.t()
  def manifest_path(app_id, opts \\ []) when is_binary(app_id) do
    if AppManifest.valid_id?(app_id) do
      Path.join([apps_dir(opts), app_id, @manifest_file])
    else
      raise ArgumentError, "invalid workbench app id: #{inspect(app_id)}"
    end
  end

  @spec list(keyword()) :: [AppManifest.t()]
  def list(opts \\ []) do
    opts
    |> load_all()
    |> Map.fetch!("apps")
  end

  @spec load_all(keyword()) :: map()
  def load_all(opts \\ []) do
    apps_root = apps_dir(opts)

    case File.ls(apps_root) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce(%{"apps" => [], "diagnostics" => []}, fn name, acc ->
          path = Path.join(apps_root, name)

          if File.dir?(path) do
            manifest_path = Path.join(path, @manifest_file)
            merge_load_result(acc, name, manifest_path, load_manifest(manifest_path))
          else
            acc
          end
        end)
        |> sort_apps()

      {:error, :enoent} ->
        %{"apps" => [], "diagnostics" => []}

      {:error, reason} ->
        %{
          "apps" => [],
          "diagnostics" => [
            diagnostic(apps_root, "failed to list workbench apps: #{:file.format_error(reason)}")
          ]
        }
    end
  end

  @spec get(String.t(), keyword()) :: {:ok, AppManifest.t()} | {:error, String.t()}
  def get(app_id, opts \\ []) when is_binary(app_id) do
    with :ok <- validate_app_id(app_id) do
      case load_manifest(manifest_path(app_id, opts)) do
        {:ok, manifest} -> {:ok, manifest}
        {:error, diagnostic} -> {:error, diagnostic["error"]}
      end
    end
  end

  @spec save(map(), keyword()) :: {:ok, AppManifest.t()} | {:error, String.t()}
  def save(attrs, opts \\ [])

  def save(attrs, opts) when is_map(attrs) do
    with {:ok, %AppManifest{} = manifest} <- AppManifest.normalize(attrs),
         :ok <- write_manifest(manifest, opts) do
      {:ok, manifest}
    end
  end

  def save(_attrs, _opts), do: {:error, "manifest must be a JSON object"}

  defp validate_app_id(app_id) do
    if AppManifest.valid_id?(app_id) do
      :ok
    else
      {:error, "id must match ^[a-z][a-z0-9_-]{1,63}$"}
    end
  end

  defp load_manifest(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, manifest} <- AppManifest.normalize(decoded) do
      {:ok, manifest}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, diagnostic(path, "invalid JSON: #{Exception.message(error)}")}

      {:error, reason} when is_binary(reason) ->
        {:error, diagnostic(path, reason)}

      {:error, :enoent} ->
        {:error, diagnostic(path, "manifest file is missing")}

      {:error, reason} ->
        {:error, diagnostic(path, "failed to read manifest: #{format_reason(reason)}")}
    end
  end

  defp write_manifest(%AppManifest{} = manifest, opts) do
    path = manifest_path(manifest.id, opts)
    tmp_path = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    content = Jason.encode!(AppManifest.to_map(manifest), pretty: true) <> "\n"

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp_path, content),
           :ok <- File.rename(tmp_path, path) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, "failed to save manifest: #{format_reason(reason)}"}
    end
  end

  defp merge_load_result(acc, app_id, path, {:ok, %AppManifest{} = manifest}) do
    if manifest.id == app_id do
      Map.update!(acc, "apps", &[manifest | &1])
    else
      diagnostic =
        diagnostic(
          path,
          "manifest id #{inspect(manifest.id)} does not match app directory #{inspect(app_id)}",
          app_id
        )

      Map.update!(acc, "diagnostics", &[diagnostic | &1])
    end
  end

  defp merge_load_result(acc, app_id, _path, {:error, diagnostic}) do
    diagnostic = Map.put_new(diagnostic, "app_id", app_id)
    Map.update!(acc, "diagnostics", &[diagnostic | &1])
  end

  defp sort_apps(%{"apps" => apps, "diagnostics" => diagnostics}) do
    %{
      "apps" => Enum.sort_by(apps, & &1.id),
      "diagnostics" => Enum.reverse(diagnostics)
    }
  end

  defp diagnostic(path, error, app_id \\ nil) do
    %{
      "path" => path,
      "error" => truncate(to_string(error))
    }
    |> maybe_put("app_id", app_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_reason(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()
  defp format_reason(reason), do: inspect(reason)

  defp truncate(value) when is_binary(value) do
    if String.length(value) > @diagnostic_limit do
      String.slice(value, 0, @diagnostic_limit) <> "...[truncated]"
    else
      value
    end
  end
end
