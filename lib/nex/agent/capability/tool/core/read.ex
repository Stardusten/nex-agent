defmodule Nex.Agent.Capability.Tool.Core.Read do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Sandbox.FileSystem
  alias Nex.Agent.Runtime.Workspace

  @default_max_bytes 50_000
  @default_directory_limit 200
  @max_directory_limit 1_000

  def name, do: "read"

  def description,
    do: "Read files or directories with pagination, metadata, and continuation info."

  def category, do: :base
  def surfaces, do: [:all, :base, :follow_up, :subagent, :cron]

  def definition do
    %{
      name: "read",
      description:
        "Read a file or inspect a directory. Returns structured content, metadata, and continuation fields for long files.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Path to file"},
          start_line: %{
            type: "integer",
            description: "1-based starting line for file reads",
            minimum: 1
          },
          line_count: %{
            type: "integer",
            description: "Maximum number of lines to return for file reads",
            minimum: 1
          },
          max_bytes: %{
            type: "integer",
            description: "Soft byte cap for returned file content",
            minimum: 1
          },
          include_stat: %{type: "boolean", description: "Include file or directory stat metadata"},
          directory: %{
            type: "object",
            description: "Directory listing options. When present, path must be a directory.",
            properties: %{
              depth: %{type: "integer", minimum: 0, description: "Recursive depth to include"},
              limit: %{type: "integer", minimum: 1, description: "Maximum entries to return"}
            }
          }
        },
        required: ["path"]
      }
    }
  end

  def execute(%{"path" => path} = args, ctx) do
    with {:ok, info} <- FileSystem.authorize(path, :read, ctx),
         :ok <- reject_profile_shadow(info.expanded_path),
         {:ok, kind} <- classify_path(info) do
      case {kind, Map.get(args, "directory")} do
        {:file, nil} ->
          read_file(info, args)

        {:file, _directory_opts} ->
          {:error, "directory options require a directory path"}

        {:directory, nil} ->
          {:error, "Path is a directory. Provide directory options to inspect entries."}

        {:directory, directory_opts} ->
          read_directory(info, directory_opts || %{}, args, ctx)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_args, _ctx), do: {:error, "path is required"}

  defp classify_path(info) do
    with {:ok, regular?} <- FileSystem.regular?(info),
         {:ok, directory?} <- FileSystem.directory?(info) do
      cond do
        regular? -> {:ok, :file}
        directory? -> {:ok, :directory}
        true -> {:error, "Path does not exist: #{info.expanded_path}"}
      end
    end
  end

  defp read_file(info, args) do
    case FileSystem.read_file(info) do
      {:ok, content} ->
        lines = split_lines(content)
        total_lines = length(lines)
        start_line = normalize_positive(args["start_line"], 1)
        start_index = max(start_line - 1, 0)
        requested_lines = normalize_positive_or_nil(args["line_count"])
        selected = Enum.drop(lines, start_index)

        selected =
          if is_integer(requested_lines), do: Enum.take(selected, requested_lines), else: selected

        {returned_lines, end_index} =
          take_lines_with_byte_limit(
            selected,
            start_index,
            args["max_bytes"] || @default_max_bytes
          )

        content_out =
          returned_lines
          |> Enum.join("\n")
          |> maybe_restore_trailing_newline(content, end_index, total_lines)

        has_more = end_index < total_lines

        {:ok,
         %{
           status: :ok,
           path: info.expanded_path,
           kind: :file,
           truncated: has_more,
           has_more: has_more,
           next_start_line: if(has_more, do: end_index + 1, else: nil),
           content: content_out,
           total_lines: total_lines,
           entries: nil,
           stat: maybe_stat(info, Map.get(args, "include_stat", false))
         }}

      {:error, reason} ->
        {:error, "Error reading file #{info.expanded_path}: #{inspect(reason)}"}
    end
  end

  defp read_directory(info, directory_opts, args, ctx) do
    depth = normalize_non_negative(Map.get(directory_opts, "depth"), 0)
    limit = directory_limit(Map.get(directory_opts, "limit"))
    entries = directory_entries(info, depth, Map.get(args, "include_stat", false), ctx)
    total_entries = length(entries)
    start_line = normalize_positive(Map.get(args, "start_line"), 1)
    start_index = max(start_line - 1, 0)
    limited_entries = entries |> Enum.drop(start_index) |> Enum.take(limit)
    has_more = total_entries > start_index + length(limited_entries)

    {:ok,
     %{
       status: :ok,
       path: info.expanded_path,
       kind: :directory,
       truncated: has_more,
       has_more: has_more,
       next_start_line: if(has_more, do: start_index + length(limited_entries) + 1, else: nil),
       content: nil,
       total_lines: total_entries,
       entries: limited_entries,
       stat: maybe_stat(info, Map.get(args, "include_stat", false))
     }}
  end

  defp reject_profile_shadow(expanded) do
    if reserved_profile_shadow_path?(expanded) do
      {:error,
       "USER profile lives at #{Path.join(Workspace.root(), "USER.md")}. Use user_update or read workspace/USER.md directly."}
    else
      :ok
    end
  end

  defp reserved_profile_shadow_path?(expanded) do
    Enum.take(Path.split(expanded), -2) == ["memory", "USER.md"]
  end

  defp split_lines(""), do: []

  defp split_lines(content) do
    parts = String.split(content, "\n", trim: false)

    if String.ends_with?(content, "\n") do
      Enum.drop(parts, -1)
    else
      parts
    end
  end

  defp take_lines_with_byte_limit(lines, start_index, max_bytes) do
    max_bytes = normalize_positive(max_bytes, @default_max_bytes)

    {taken, count, _bytes} =
      Enum.reduce_while(lines, {[], 0, 0}, fn line, {acc, count, bytes} ->
        separator = if(count == 0, do: 0, else: 1)
        next_bytes = bytes + separator + byte_size(line)

        cond do
          count == 0 ->
            {:cont, {[line | acc], count + 1, next_bytes}}

          next_bytes <= max_bytes ->
            {:cont, {[line | acc], count + 1, next_bytes}}

          true ->
            {:halt, {acc, count, bytes}}
        end
      end)

    {Enum.reverse(taken), start_index + count}
  end

  defp maybe_restore_trailing_newline(content_out, original, end_index, total_lines) do
    if content_out != "" and end_index == total_lines and String.ends_with?(original, "\n") do
      content_out <> "\n"
    else
      content_out
    end
  end

  defp directory_entries(root_info, depth, include_stat, ctx) do
    do_directory_entries(root_info.expanded_path, root_info, depth, include_stat, ctx)
    |> Enum.sort_by(& &1.path)
  end

  defp do_directory_entries(root, current_info, depth, include_stat, ctx) do
    with {:ok, names} <- FileSystem.list_dir(current_info) do
      names
      |> Enum.sort()
      |> Enum.flat_map(fn name ->
        full_path = Path.join(current_info.expanded_path, name)

        with {:ok, child_info} <- FileSystem.authorize(full_path, :read, ctx),
             {:ok, directory?} <- FileSystem.directory?(child_info) do
          relative_path = Path.relative_to(child_info.expanded_path, root)
          kind = if(directory?, do: :directory, else: :file)

          entry =
            %{
              path: relative_path,
              name: name,
              kind: kind
            }
            |> maybe_put_entry_stat(child_info, include_stat)

          cond do
            kind == :directory and depth > 0 ->
              [entry | do_directory_entries(root, child_info, depth - 1, include_stat, ctx)]

            true ->
              [entry]
          end
        else
          {:error, _reason} -> []
        end
      end)
    else
      {:error, _reason} -> []
    end
  end

  defp maybe_put_entry_stat(entry, _info, false), do: entry

  defp maybe_put_entry_stat(entry, info, true) do
    case FileSystem.stat(info) do
      {:ok, stat} ->
        Map.merge(entry, %{size: stat.size, mtime: format_mtime(stat.mtime)})

      {:error, _reason} ->
        Map.merge(entry, %{size: nil, mtime: nil})
    end
  end

  defp maybe_stat(_path, false), do: nil

  defp maybe_stat(info, true) do
    case FileSystem.stat(info) do
      {:ok, stat} ->
        %{size: stat.size, mtime: format_mtime(stat.mtime)}

      {:error, _reason} ->
        %{size: nil, mtime: nil}
    end
  end

  defp format_mtime({{year, month, day}, {hour, minute, second}}) do
    {:ok, naive} = NaiveDateTime.new(year, month, day, hour, minute, second)
    NaiveDateTime.to_iso8601(naive)
  end

  defp format_mtime(_mtime), do: nil

  defp directory_limit(nil), do: @default_directory_limit

  defp directory_limit(limit),
    do: min(normalize_positive(limit, @default_directory_limit), @max_directory_limit)

  defp normalize_positive(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive(_value, default), do: default

  defp normalize_positive_or_nil(value) when is_integer(value) and value > 0, do: value
  defp normalize_positive_or_nil(_value), do: nil

  defp normalize_non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative(_value, default), do: default
end
