defmodule Nex.Agent.Extension.Plugin.Store do
  @moduledoc """
  File-backed plugin manifest discovery.
  """

  alias Nex.Agent.Extension.Plugin.Manifest
  alias Nex.Agent.Runtime.Workspace

  @manifest_file "nex.plugin.json"
  @diagnostic_limit 500

  @type result :: %{
          required(String.t()) => [Manifest.t()] | [map()]
        }

  @spec builtin_dir(keyword()) :: String.t()
  def builtin_dir(opts \\ []) do
    Keyword.get(opts, :builtin_plugins_dir) || default_builtin_dir()
  end

  @spec workspace_dir(keyword()) :: String.t()
  def workspace_dir(opts \\ []) do
    Keyword.get(opts, :workspace_plugins_dir) || Workspace.plugins_dir(opts)
  end

  @spec load_all(keyword()) :: result()
  def load_all(opts \\ []) do
    [
      {:builtin, builtin_dir(opts)},
      {:workspace, workspace_dir(opts)}
    ]
    |> maybe_project_source(opts)
    |> Enum.reduce(%{"manifests" => [], "diagnostics" => []}, fn {source, root}, acc ->
      merge_source(acc, load_source(source, root))
    end)
    |> sort_result()
  end

  @spec manifest_path(String.t(), keyword()) :: String.t()
  def manifest_path(id, opts \\ []) when is_binary(id) do
    source =
      Manifest.source_from_id(id) ||
        raise ArgumentError, "invalid plugin id: #{inspect(id)}"

    name = id |> String.split(":", parts: 2) |> List.last()
    Path.join([source_dir(source, opts), name, @manifest_file])
  end

  defp maybe_project_source(sources, opts) do
    case Keyword.get(opts, :project_plugins_dir) do
      path when is_binary(path) -> sources ++ [{:project, path}]
      _ -> sources
    end
  end

  defp source_dir(:builtin, opts), do: builtin_dir(opts)
  defp source_dir(:workspace, opts), do: workspace_dir(opts)
  defp source_dir(:project, opts), do: Keyword.fetch!(opts, :project_plugins_dir)

  defp load_source(source, root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce(%{"manifests" => [], "diagnostics" => []}, fn name, acc ->
          path = Path.join(root, name)

          if File.dir?(path) do
            merge_load_result(acc, source, name, Path.join(path, @manifest_file))
          else
            acc
          end
        end)

      {:error, :enoent} ->
        %{"manifests" => [], "diagnostics" => []}

      {:error, reason} ->
        %{
          "manifests" => [],
          "diagnostics" => [
            diagnostic(root, "failed to list #{source} plugins: #{format_reason(reason)}")
          ]
        }
    end
  end

  defp merge_load_result(acc, source, name, path) do
    case load_manifest(source, path) do
      {:ok, %Manifest{} = manifest} ->
        if plugin_dir_matches?(manifest.id, name) do
          Map.update!(acc, "manifests", &[manifest | &1])
        else
          diagnostic =
            diagnostic(
              path,
              "manifest id #{inspect(manifest.id)} does not match plugin directory #{inspect(name)}"
            )

          Map.update!(acc, "diagnostics", &[diagnostic | &1])
        end

      {:error, diagnostic} ->
        Map.update!(acc, "diagnostics", &[Map.put_new(diagnostic, "plugin_dir", name) | &1])
    end
  end

  defp load_manifest(source, path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, manifest} <- Manifest.normalize(decoded, source: source, path: path) do
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

  defp merge_source(acc, %{"manifests" => manifests, "diagnostics" => diagnostics}) do
    acc
    |> Map.update!("manifests", &(manifests ++ &1))
    |> Map.update!("diagnostics", &(diagnostics ++ &1))
  end

  defp sort_result(%{"manifests" => manifests, "diagnostics" => diagnostics}) do
    %{
      "manifests" => Enum.sort_by(manifests, & &1.id),
      "diagnostics" => Enum.reverse(diagnostics)
    }
  end

  defp plugin_dir_matches?(id, name) do
    case String.split(id, ":", parts: 2) do
      [_source, ^name] -> true
      _ -> false
    end
  end

  defp diagnostic(path, error) do
    %{
      "path" => path,
      "error" => truncate(to_string(error))
    }
  end

  defp default_builtin_dir do
    app_priv =
      case :code.priv_dir(:nex_agent) do
        path when is_list(path) -> Path.join(to_string(path), "plugins/builtin")
        _ -> nil
      end

    cond do
      is_binary(app_priv) and File.dir?(app_priv) -> app_priv
      true -> Path.expand("priv/plugins/builtin")
    end
  end

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
