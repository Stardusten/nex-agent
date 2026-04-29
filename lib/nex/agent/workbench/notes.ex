defmodule Nex.Agent.Workbench.Notes do
  @moduledoc false

  alias Nex.Agent.{Config, Security}
  alias Nex.Agent.ControlPlane.Log
  require Log

  @root_id "notes"
  @max_files 1_000
  @max_results 200
  @max_file_bytes 2_000_000
  @snippet_radius 80

  @type bridge_result :: {:ok, map()} | {:error, String.t(), String.t()}

  @spec roots_list(map(), keyword()) :: bridge_result()
  def roots_list(params, opts) do
    with :ok <- ensure_only_keys(params, []),
         {:ok, root} <- configured_root(opts, allow_missing: true) do
      roots =
        case root do
          nil ->
            []

          root ->
            [
              %{
                "id" => @root_id,
                "title" => root_title(root),
                "configured" => true
              }
            ]
        end

      _ = Log.info("workbench.notes.roots.listed", %{"count" => length(roots)}, opts)
      {:ok, %{"roots" => roots}}
    end
  end

  @spec files_list(map(), keyword()) :: bridge_result()
  def files_list(params, opts) do
    with :ok <- ensure_only_keys(params, ~w(root_id query limit)),
         {:ok, root} <- root_from_params(params, opts),
         {:ok, limit} <- parse_limit(Map.get(params, "limit", 300), @max_files) do
      query = params |> Map.get("query", "") |> to_string() |> String.trim()

      files =
        root
        |> markdown_files(opts)
        |> filter_files(query)
        |> Enum.take(limit)
        |> Enum.map(&file_entry(&1, root))

      _ =
        Log.info(
          "workbench.notes.files.listed",
          %{"root_id" => @root_id, "count" => length(files), "query" => query},
          opts
        )

      {:ok, %{"root_id" => @root_id, "files" => files}}
    end
  end

  @spec file_read(map(), keyword()) :: bridge_result()
  def file_read(params, opts) do
    with :ok <- ensure_only_keys(params, ~w(root_id path)),
         {:ok, root} <- root_from_params(params, opts),
         {:ok, path, relative_path} <- resolve_existing_markdown(params["path"], root, opts),
         {:ok, content} <- read_text_file(path) do
      stat = file_stat(path)

      _ =
        Log.info(
          "workbench.notes.file.read",
          %{"root_id" => @root_id, "path" => relative_path, "size" => byte_size(content)},
          opts
        )

      {:ok,
       %{
         "root_id" => @root_id,
         "path" => relative_path,
         "content" => content,
         "revision" => revision(content),
         "size" => byte_size(content),
         "modified_at" => modified_at(stat)
       }}
    end
  end

  @spec file_write(map(), keyword()) :: bridge_result()
  def file_write(params, opts) do
    with :ok <- ensure_only_keys(params, ~w(root_id path content base_revision)),
         {:ok, root} <- root_from_params(params, opts),
         {:ok, content} <- content_param(params),
         {:ok, path, relative_path} <- resolve_write_markdown(params["path"], root, opts),
         :ok <- ensure_base_revision(path, Map.get(params, "base_revision")),
         :ok <- atomic_write(path, content, root, opts),
         {:ok, written} <- read_text_file(path) do
      stat = file_stat(path)

      _ =
        Log.info(
          "workbench.notes.file.written",
          %{"root_id" => @root_id, "path" => relative_path, "size" => byte_size(written)},
          opts
        )

      {:ok,
       %{
         "root_id" => @root_id,
         "path" => relative_path,
         "revision" => revision(written),
         "size" => byte_size(written),
         "modified_at" => modified_at(stat)
       }}
    end
  end

  @spec file_delete(map(), keyword()) :: bridge_result()
  def file_delete(params, opts) do
    with :ok <- ensure_only_keys(params, ~w(root_id path base_revision)),
         {:ok, root} <- root_from_params(params, opts),
         {:ok, path, relative_path} <- resolve_existing_markdown(params["path"], root, opts),
         :ok <- ensure_base_revision(path, Map.get(params, "base_revision")),
         :ok <- delete_file(path),
         :ok <- prune_empty_parents(Path.dirname(path), root) do
      _ =
        Log.info(
          "workbench.notes.file.deleted",
          %{"root_id" => @root_id, "path" => relative_path},
          opts
        )

      {:ok, %{"root_id" => @root_id, "path" => relative_path, "deleted" => true}}
    end
  end

  @spec search(map(), keyword()) :: bridge_result()
  def search(params, opts) do
    with :ok <- ensure_only_keys(params, ~w(root_id query limit)),
         {:ok, root} <- root_from_params(params, opts),
         {:ok, query} <- query_param(params),
         {:ok, limit} <- parse_limit(Map.get(params, "limit", 50), @max_results) do
      results =
        root
        |> markdown_files(opts)
        |> Enum.reduce_while([], fn path, acc ->
          if length(acc) >= limit do
            {:halt, acc}
          else
            case search_file(path, root, query) do
              nil -> {:cont, acc}
              result -> {:cont, [result | acc]}
            end
          end
        end)
        |> Enum.reverse()

      _ =
        Log.info(
          "workbench.notes.search.completed",
          %{"root_id" => @root_id, "query" => query, "count" => length(results)},
          opts
        )

      {:ok, %{"root_id" => @root_id, "query" => query, "results" => results}}
    end
  end

  defp configured_root(opts, options \\ []) do
    config = config_from_opts(opts)
    root = config && Config.workbench_app_config(config, "notes")["root"]

    cond do
      is_binary(root) and root != "" ->
        root = Path.expand(root)

        case Security.validate_path(root, Keyword.put(opts, :extra_allowed_roots, [root])) do
          {:ok, expanded} -> {:ok, expanded}
          {:error, reason} -> fail("root_unavailable", reason, opts)
        end

      Keyword.get(options, :allow_missing, false) ->
        {:ok, nil}

      true ->
        fail("root_missing", "gateway.workbench.apps.notes.root is not configured", opts)
    end
  end

  defp root_from_params(params, opts) do
    with :ok <- require_root_id(params),
         {:ok, root} <- configured_root(opts) do
      {:ok, root}
    end
  end

  defp require_root_id(params) do
    case params |> Map.get("root_id") |> to_string() |> String.trim() do
      @root_id -> :ok
      "" -> {:error, "root_id is required"}
      other -> {:error, "unknown root_id: #{other}"}
    end
  end

  defp resolve_existing_markdown(path, root, opts) do
    with {:ok, path, relative_path} <- resolve_markdown_path(path, root, opts),
         true <- File.regular?(path) do
      {:ok, path, relative_path}
    else
      false -> fail("not_found", "note file not found", opts)
      {:error, code, reason} -> {:error, code, reason}
    end
  end

  defp resolve_write_markdown(path, root, opts), do: resolve_markdown_path(path, root, opts)

  defp resolve_markdown_path(path, root, opts) when is_binary(path) do
    relative_path = normalize_relative_path(path)

    with {:ok, relative_path} <- relative_path,
         :ok <- ensure_markdown_path(relative_path),
         full_path = Path.expand(relative_path, root),
         true <- under_root?(full_path, root),
         {:ok, expanded} <-
           Security.validate_write_path(
             full_path,
             Keyword.put(opts, :extra_allowed_roots, [root])
           ),
         {:ok, real_parent} <- real_parent(expanded),
         true <- under_root?(real_parent, root) do
      {:ok, expanded, relative_path}
    else
      false -> fail("path_forbidden", "path is outside notes root", opts)
      {:error, %{} = error} -> {:error, error["code"], error["message"]}
      {:error, reason} when is_binary(reason) -> fail("path_forbidden", reason, opts)
      {:error, code, reason} -> {:error, code, reason}
    end
  end

  defp resolve_markdown_path(_path, _root, opts),
    do: fail("bad_params", "path must be a string", opts)

  defp normalize_relative_path(path) do
    path = path |> String.trim() |> String.replace("\\", "/")

    cond do
      path == "" ->
        {:error, %{"code" => "bad_params", "message" => "path is required"}}

      Path.type(path) == :absolute ->
        {:error, %{"code" => "path_forbidden", "message" => "absolute paths are not allowed"}}

      path |> String.split("/") |> Enum.any?(&(&1 in ["", ".", ".."])) ->
        {:error, %{"code" => "path_forbidden", "message" => "path traversal is not allowed"}}

      true ->
        {:ok, path}
    end
  end

  defp ensure_markdown_path(path) do
    if String.ends_with?(String.downcase(path), ".md") do
      :ok
    else
      {:error, "only Markdown .md files are supported"}
    end
  end

  defp under_root?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp real_parent(path) do
    parent = Path.dirname(path)

    parent
    |> String.to_charlist()
    |> :file.read_link_all()
    |> case do
      {:ok, resolved} -> {:ok, resolved |> List.to_string() |> Path.expand()}
      {:error, _reason} -> {:ok, Path.expand(parent)}
    end
  end

  defp markdown_files(root, opts) do
    root
    |> walk(root, opts)
    |> Enum.sort_by(&String.downcase(relative_to_root(&1, root)))
  end

  defp walk(dir, root, opts) do
    with {:ok, _} <- Security.validate_path(dir, Keyword.put(opts, :extra_allowed_roots, [root])),
         {:ok, entries} <- File.ls(dir) do
      entries
      |> Enum.sort()
      |> Enum.flat_map(fn entry ->
        path = Path.join(dir, entry)

        cond do
          File.dir?(path) ->
            walk(path, root, opts)

          File.regular?(path) and markdown_path?(path) ->
            case Security.validate_path(path, Keyword.put(opts, :extra_allowed_roots, [root])) do
              {:ok, expanded} -> [expanded]
              {:error, _reason} -> []
            end

          true ->
            []
        end
      end)
    else
      _ -> []
    end
  end

  defp markdown_path?(path), do: String.ends_with?(String.downcase(path), ".md")

  defp filter_files(files, ""), do: files

  defp filter_files(files, query) do
    query = String.downcase(query)

    Enum.filter(files, fn path ->
      path
      |> Path.basename(".md")
      |> String.downcase()
      |> String.contains?(query)
    end)
  end

  defp file_entry(path, root) do
    stat = file_stat(path)
    relative_path = relative_to_root(path, root)

    %{
      "path" => relative_path,
      "title" => title(relative_path),
      "size" => (stat && stat.size) || 0,
      "modified_at" => modified_at(stat)
    }
  end

  defp search_file(path, root, query) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= @max_file_bytes,
         {:ok, content} <- read_text_file(path),
         {:ok, index} <- find_case_insensitive(content, query) do
      relative_path = relative_to_root(path, root)

      %{
        "path" => relative_path,
        "title" => title(relative_path),
        "snippet" => snippet(content, index, String.length(query))
      }
    else
      _ -> nil
    end
  end

  defp find_case_insensitive(content, query) do
    content_downcase = String.downcase(content)
    query_downcase = String.downcase(query)

    case :binary.match(content_downcase, query_downcase) do
      {index, _length} -> {:ok, index}
      :nomatch -> :error
    end
  end

  defp snippet(content, index, length) do
    start = max(index - @snippet_radius, 0)
    finish = min(index + length + @snippet_radius, String.length(content))

    prefix = if start > 0, do: "...", else: ""
    suffix = if finish < String.length(content), do: "...", else: ""

    text =
      content
      |> String.slice(start, finish - start)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    prefix <> text <> suffix
  end

  defp content_param(params) do
    content = Map.get(params, "content")

    cond do
      not is_binary(content) ->
        {:error, "bad_params", "content must be a string"}

      byte_size(content) > @max_file_bytes ->
        {:error, "bad_params", "content is too large"}

      true ->
        {:ok, content}
    end
  end

  defp query_param(params) do
    query = params |> Map.get("query", "") |> to_string() |> String.trim()

    if query == "" do
      {:error, "bad_params", "query is required"}
    else
      {:ok, query}
    end
  end

  defp ensure_base_revision(path, nil), do: ensure_base_revision(path, "")
  defp ensure_base_revision(_path, ""), do: :ok

  defp ensure_base_revision(path, base_revision) when is_binary(base_revision) do
    current_revision =
      if File.regular?(path) do
        case read_text_file(path) do
          {:ok, content} -> revision(content)
          {:error, _code, _reason} -> nil
        end
      end

    if current_revision == base_revision do
      :ok
    else
      {:error, "conflict", "note changed on disk; reload before saving"}
    end
  end

  defp ensure_base_revision(_path, _base_revision),
    do: {:error, "bad_params", "base_revision must be a string"}

  defp atomic_write(path, content, root, opts) do
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, _} <-
           Security.validate_write_path(tmp_path, Keyword.put(opts, :extra_allowed_roots, [root])),
         :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, "write_failed", to_string(reason)}
    end
  end

  defp delete_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "delete_failed", to_string(reason)}
    end
  end

  defp prune_empty_parents(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)

    cond do
      path == root ->
        :ok

      not under_root?(path, root) ->
        :ok

      true ->
        case File.rmdir(path) do
          :ok -> prune_empty_parents(Path.dirname(path), root)
          {:error, :eexist} -> :ok
          {:error, :enotempty} -> :ok
          {:error, :enoent} -> prune_empty_parents(Path.dirname(path), root)
          {:error, _reason} -> :ok
        end
    end
  end

  defp read_text_file(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= @max_file_bytes,
         {:ok, content} <- File.read(path),
         true <- String.valid?(content) do
      {:ok, content}
    else
      false -> {:error, "read_failed", "note file is too large or not valid UTF-8"}
      {:error, reason} -> {:error, "read_failed", to_string(reason)}
    end
  end

  defp revision(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp file_stat(path) do
    case File.stat(path) do
      {:ok, stat} -> stat
      {:error, _reason} -> nil
    end
  end

  defp modified_at(nil), do: nil

  defp modified_at(%File.Stat{mtime: mtime}) do
    mtime
    |> NaiveDateTime.from_erl!()
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  rescue
    _ -> nil
  end

  defp relative_to_root(path, root),
    do: path |> Path.relative_to(root) |> String.replace("\\", "/")

  defp title(relative_path), do: relative_path |> Path.basename(".md") |> String.replace("_", " ")
  defp root_title(root), do: root |> Path.basename() |> blank_to("Notes")
  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value

  defp parse_limit(value, max) when is_integer(value) and value > 0, do: {:ok, min(value, max)}

  defp parse_limit(value, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, min(parsed, max)}
      _ -> {:error, "bad_params", "limit must be a positive integer"}
    end
  end

  defp parse_limit(_value, _max), do: {:error, "bad_params", "limit must be a positive integer"}

  defp ensure_only_keys(params, allowed_keys) when is_map(params) do
    allowed = MapSet.new(allowed_keys)

    case params
         |> Map.keys()
         |> Enum.map(&to_string/1)
         |> Enum.reject(&MapSet.member?(allowed, &1)) do
      [] -> :ok
      [key | _] -> {:error, "bad_params", "unsupported param: #{key}"}
    end
  end

  defp config_from_opts(opts) do
    Keyword.get(opts, :config) || snapshot_config(Keyword.get(opts, :runtime_snapshot))
  end

  defp snapshot_config(%{config: %Config{} = config}), do: config
  defp snapshot_config(_snapshot), do: nil

  defp fail(code, reason, opts) do
    _ =
      Log.warning(
        "workbench.notes.call.failed",
        %{"code" => code, "reason" => bounded(reason)},
        opts
      )

    {:error, code, reason}
  end

  defp bounded(reason) do
    reason = to_string(reason)

    if String.length(reason) > 500 do
      String.slice(reason, 0, 500) <> "...[truncated]"
    else
      reason
    end
  end
end
