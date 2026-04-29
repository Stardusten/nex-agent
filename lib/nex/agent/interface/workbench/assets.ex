defmodule Nex.Agent.Interface.Workbench.Assets do
  @moduledoc false

  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Interface.Workbench.{Shell, Store}
  require Log

  @manifest_file "nex.app.json"
  @max_asset_bytes 2 * 1024 * 1024
  @message_limit 500

  @type asset :: %{
          content_type: String.t(),
          body: binary()
        }

  @spec app_frame(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, pos_integer(), String.t()}
  def app_frame(app_id, opts \\ []) when is_binary(app_id) do
    case Store.get(app_id, opts) do
      {:ok, manifest} ->
        case read_app_file(app_id, manifest.entry, opts) do
          {:ok, %{body: body}} ->
            _ =
              Log.info(
                "workbench.app.frame.served",
                %{"app_id" => app_id, "entry" => manifest.entry, "bytes" => byte_size(body)},
                opts
              )

            {:ok, Shell.inject_sdk_bootstrap(body, app_id)}

          {:error, reason} ->
            _ = frame_failed(app_id, manifest.entry, reason, opts)
            {:error, 200, Shell.frame_error("App entry unavailable", bounded(reason))}
        end

      {:error, reason} ->
        _ = frame_failed(app_id, nil, reason, opts)
        {:error, 404, Shell.frame_error("Missing app", bounded(reason))}
    end
  end

  @spec asset(String.t(), String.t(), keyword()) ::
          {:ok, asset()} | {:error, pos_integer(), String.t()}
  def asset(app_id, relative_path, opts \\ [])
      when is_binary(app_id) and is_binary(relative_path) do
    with {:ok, _manifest} <- Store.get(app_id, opts),
         {:ok, asset} <- read_app_file(app_id, relative_path, opts) do
      _ =
        Log.info(
          "workbench.app.asset.served",
          %{
            "app_id" => app_id,
            "path" => relative_path,
            "content_type" => asset.content_type,
            "bytes" => byte_size(asset.body)
          },
          opts
        )

      {:ok, asset}
    else
      {:error, reason} when is_binary(reason) ->
        _ = asset_failed(app_id, relative_path, reason, opts)
        {:error, status_for(reason), bounded(reason)}
    end
  end

  @spec content_type(String.t()) :: String.t()
  def content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".html" -> "text/html"
      ".js" -> "application/javascript"
      ".css" -> "text/css"
      ".json" -> "application/json"
      ".svg" -> "image/svg+xml"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".txt" -> "text/plain"
      _ -> "application/octet-stream"
    end
  end

  defp read_app_file(app_id, relative_path, opts) do
    with {:ok, path} <- resolve_app_path(app_id, relative_path, opts),
         {:ok, stat} <- stat_file(path),
         :ok <- ensure_regular_file(stat),
         :ok <- ensure_size(stat),
         {:ok, body} <- File.read(path) do
      {:ok, %{content_type: content_type(relative_path), body: body}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, format_file_error(reason)}
    end
  end

  defp resolve_app_path(app_id, relative_path, opts) do
    app_root = Path.expand(Path.join(Store.apps_dir(opts), app_id))
    apps_root = Path.expand(Store.apps_dir(opts))

    with :ok <- validate_relative_path(relative_path),
         :ok <- ensure_manifest_not_requested(relative_path),
         target = Path.expand(Path.join(app_root, relative_path)),
         true <- within?(target, app_root),
         {:ok, real_apps_root} <- realpath_if_possible(apps_root),
         {:ok, real_app_root} <- realpath_if_possible(app_root),
         true <- within?(real_app_root, real_apps_root),
         {:ok, real_target} <- realpath_if_possible(target),
         true <- within?(real_target, real_app_root) do
      {:ok, target}
    else
      false -> {:error, "asset path escapes app directory"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_relative_path(path) when is_binary(path) do
    path = String.trim(path)
    segments = Path.split(path)

    cond do
      path == "" -> {:error, "asset path is required"}
      Path.type(path) != :relative -> {:error, "asset path must be relative"}
      Enum.any?(segments, &(&1 == "..")) -> {:error, "asset path must not contain .. segments"}
      true -> :ok
    end
  end

  defp ensure_manifest_not_requested(relative_path) do
    if relative_path |> Path.split() |> Enum.any?(&(&1 == @manifest_file)) do
      {:error, "#{@manifest_file} is not served as an app asset"}
    else
      :ok
    end
  end

  defp stat_file(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, "asset file is missing"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_regular_file(%File.Stat{type: :regular}), do: :ok

  defp ensure_regular_file(%File.Stat{type: :directory}),
    do: {:error, "asset path is a directory"}

  defp ensure_regular_file(_stat), do: {:error, "asset path is not a regular file"}

  defp ensure_size(%File.Stat{size: size}) when is_integer(size) and size <= @max_asset_bytes,
    do: :ok

  defp ensure_size(_stat), do: {:error, "asset file exceeds 2MB limit"}

  defp status_for("asset file is missing"), do: 404
  defp status_for("unknown workbench app" <> _), do: 404
  defp status_for("manifest file is missing"), do: 404
  defp status_for(_reason), do: 400

  defp frame_failed(app_id, entry, reason, opts) do
    Log.warning(
      "workbench.app.frame.failed",
      %{"app_id" => app_id, "entry" => entry, "reason" => bounded(reason)},
      opts
    )
  end

  defp asset_failed(app_id, relative_path, reason, opts) do
    Log.warning(
      "workbench.app.asset.failed",
      %{"app_id" => app_id, "path" => relative_path, "reason" => bounded(reason)},
      opts
    )
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp realpath_if_possible(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_segments(0)
  end

  defp resolve_segments(["/" | segments], depth), do: resolve_segments("/", segments, depth)
  defp resolve_segments(segments, depth), do: resolve_segments("/", segments, depth)

  defp resolve_segments(current, [], _depth), do: {:ok, current}

  defp resolve_segments(_current, _segments, depth) when depth > 40,
    do: {:error, "too many symlink hops"}

  defp resolve_segments(current, [segment | rest], depth) do
    next = Path.join(current, segment)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(next) do
          target =
            if Path.type(target) == :absolute do
              Path.expand(target)
            else
              Path.expand(target, current)
            end

          target
          |> Path.split()
          |> append_segments(rest)
          |> resolve_segments(depth + 1)
        end

      {:ok, _stat} ->
        resolve_segments(next, rest, depth)

      {:error, :enoent} ->
        {:ok, Enum.reduce([segment | rest], current, fn part, acc -> Path.join(acc, part) end)}

      {:error, reason} ->
        {:error, format_file_error(reason)}
    end
  end

  defp append_segments(["/" | segments], rest), do: ["/" | segments ++ rest]
  defp append_segments(segments, rest), do: segments ++ rest

  defp format_file_error(reason) when is_atom(reason),
    do: :file.format_error(reason) |> to_string()

  defp format_file_error(reason), do: inspect(reason, limit: 20, printable_limit: 120)

  defp bounded(reason) do
    reason = to_string(reason)

    if String.length(reason) > @message_limit do
      String.slice(reason, 0, @message_limit) <> "...[truncated]"
    else
      reason
    end
  end
end
