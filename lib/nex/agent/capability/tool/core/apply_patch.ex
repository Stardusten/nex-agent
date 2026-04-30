defmodule Nex.Agent.Capability.Tool.Core.ApplyPatch do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Sandbox.FileSystem
  alias Nex.Agent.Runtime.Workspace

  @begin_marker "*** Begin Patch"
  @end_marker "*** End Patch"
  @update_prefix "*** Update File: "
  @add_prefix "*** Add File: "
  @delete_prefix "*** Delete File: "
  @move_prefix "*** Move to: "
  @end_of_file_marker "*** End of File"

  def name, do: "apply_patch"
  def description, do: "Apply deterministic multi-file patch blocks for code and text edits."
  def category, do: :base
  def surfaces, do: [:all, :base, :subagent]

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          patch: %{type: "string", description: "Patch text in Codex apply_patch format"}
        },
        required: ["patch"]
      }
    }
  end

  def execute(%{"patch" => patch}, ctx) when is_binary(patch) and patch != "" do
    with {:ok, operations} <- parse_patch(patch),
         {:ok, prepared_ops} <- prepare_operations(operations, ctx),
         :ok <- apply_operations(prepared_ops) do
      {:ok,
       %{
         status: :ok,
         updated_files: prepared_ops |> Enum.flat_map(&updated_files/1) |> Enum.uniq(),
         created_files: prepared_ops |> Enum.flat_map(&created_files/1) |> Enum.uniq(),
         deleted_files: prepared_ops |> Enum.flat_map(&deleted_files/1) |> Enum.uniq()
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_args, _ctx), do: {:error, "patch is required"}

  defp parse_patch(patch) do
    lines = normalize_patch_lines(patch)

    with :ok <- validate_envelope(lines) do
      body = lines |> Enum.drop(1) |> Enum.drop(-1)
      parse_operations(body, [])
    end
  end

  defp validate_envelope(lines) do
    cond do
      lines == [] ->
        {:error, "Invalid patch: empty input"}

      List.first(lines) != @begin_marker ->
        {:error, "Invalid patch: missing *** Begin Patch"}

      List.last(lines) != @end_marker ->
        {:error, "Invalid patch: missing *** End Patch"}

      true ->
        :ok
    end
  end

  defp normalize_patch_lines(patch) do
    patch
    |> String.split("\n", trim: false)
    |> then(fn lines ->
      if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
    end)
  end

  defp parse_operations([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_operations([line | rest], acc) do
    cond do
      String.starts_with?(line, @update_prefix) ->
        path = String.replace_prefix(line, @update_prefix, "")
        {body, tail} = take_operation_body(rest, [])

        with {:ok, operation} <- parse_update_operation(path, body) do
          parse_operations(tail, [operation | acc])
        end

      String.starts_with?(line, @add_prefix) ->
        path = String.replace_prefix(line, @add_prefix, "")
        {body, tail} = take_operation_body(rest, [])

        with {:ok, operation} <- parse_add_operation(path, body) do
          parse_operations(tail, [operation | acc])
        end

      String.starts_with?(line, @delete_prefix) ->
        path = String.replace_prefix(line, @delete_prefix, "")
        parse_operations(rest, [%{type: :delete, path: path} | acc])

      String.trim(line) == "" ->
        parse_operations(rest, acc)

      true ->
        {:error, "Invalid patch line: #{line}"}
    end
  end

  defp take_operation_body([], acc), do: {Enum.reverse(acc), []}

  defp take_operation_body([line | rest] = remaining, acc) do
    if operation_header?(line) do
      {Enum.reverse(acc), remaining}
    else
      take_operation_body(rest, [line | acc])
    end
  end

  defp operation_header?(line) do
    String.starts_with?(line, @update_prefix) or
      String.starts_with?(line, @add_prefix) or
      String.starts_with?(line, @delete_prefix)
  end

  defp parse_add_operation(path, body) do
    cond do
      body == [] ->
        {:error, "Add File patches must include at least one added line"}

      Enum.all?(body, &String.starts_with?(&1, "+")) ->
        content =
          body
          |> Enum.map(&String.replace_prefix(&1, "+", ""))
          |> Enum.join("\n")
          |> Kernel.<>("\n")

        {:ok, %{type: :add, path: path, content: content}}

      true ->
        {:error, "Add File patches may only contain added lines"}
    end
  end

  defp parse_update_operation(path, body) do
    {move_to, change_lines} =
      case body do
        [move_line | rest] when is_binary(move_line) ->
          if String.starts_with?(move_line, @move_prefix) do
            {String.replace_prefix(move_line, @move_prefix, ""), rest}
          else
            {nil, body}
          end

        _ ->
          {nil, body}
      end

    hunks =
      change_lines
      |> Enum.reject(&(&1 == @end_of_file_marker))
      |> split_hunks([])

    cond do
      move_to == nil and hunks == [] ->
        {:error, "Update File patch requires at least one hunk or Move to"}

      Enum.any?(hunks, &invalid_hunk_line?/1) ->
        {:error, "Update File patch contains invalid hunk lines"}

      true ->
        {:ok, %{type: :update, path: path, move_to: move_to, hunks: hunks}}
    end
  end

  defp split_hunks([], acc) do
    acc
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reject(&(&1 == []))
  end

  defp split_hunks([line | rest], acc) do
    cond do
      String.starts_with?(line, "@@") ->
        split_hunks(rest, [[] | acc])

      acc == [] ->
        split_hunks(rest, [[line]])

      true ->
        [current | tail] = acc
        split_hunks(rest, [[line | current] | tail])
    end
  end

  defp invalid_hunk_line?(hunk) do
    Enum.any?(hunk, fn line ->
      not (String.starts_with?(line, " ") or
             String.starts_with?(line, "+") or
             String.starts_with?(line, "-"))
    end)
  end

  defp prepare_operations(operations, ctx) do
    with :ok <- ensure_unique_targets(operations) do
      Enum.reduce_while(operations, {:ok, []}, fn operation, {:ok, acc} ->
        case prepare_operation(operation, ctx) do
          {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
        error -> error
      end
    end
  end

  defp ensure_unique_targets(operations) do
    targets =
      Enum.flat_map(operations, fn
        %{type: :add, path: path} -> [path]
        %{type: :delete, path: path} -> [path]
        %{type: :update, path: path, move_to: nil} -> [path]
        %{type: :update, path: path, move_to: move_to} -> [path, move_to]
      end)

    if Enum.uniq(targets) == targets do
      :ok
    else
      {:error, "Patch contains duplicate source or destination paths"}
    end
  end

  defp prepare_operation(%{type: :add, path: path, content: content}, ctx) do
    with {:ok, info} <- validate_mutation_target(path, ctx),
         :ok <- ensure_missing(info, path, "Add File target already exists") do
      {:ok, %{type: :add, path: info.expanded_path, path_info: info, content: content}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_operation(%{type: :delete, path: path}, ctx) do
    with {:ok, info} <- validate_mutation_target(path, ctx),
         :ok <- ensure_regular(info, path, "Delete File target does not exist"),
         {:ok, original_content} <- FileSystem.read_file(info) do
      {:ok,
       %{
         type: :delete,
         path: info.expanded_path,
         path_info: info,
         original_content: original_content
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_operation(%{type: :update, path: path, move_to: move_to, hunks: hunks}, ctx) do
    with {:ok, info} <- validate_mutation_target(path, ctx),
         :ok <- ensure_regular(info, path, "Update File target does not exist"),
         {:ok, destination_info} <- validate_update_destination(info, move_to, ctx),
         {:ok, original_content} <- FileSystem.read_file(info),
         {:ok, updated_content} <- apply_hunks(original_content, hunks) do
      {:ok,
       %{
         type: :update,
         path: info.expanded_path,
         path_info: info,
         destination: destination_info.expanded_path,
         destination_info: destination_info,
         original_content: original_content,
         updated_content: updated_content
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_update_destination(source_info, nil, _ctx), do: {:ok, source_info}

  defp validate_update_destination(source_info, move_to, ctx) do
    with {:ok, destination_info} <- validate_mutation_target(move_to, ctx),
         {:ok, destination_exists?} <- FileSystem.exists?(destination_info) do
      cond do
        destination_info.expanded_path == source_info.expanded_path ->
          {:ok, source_info}

        destination_exists? ->
          {:error, "Move destination already exists: #{move_to}"}

        true ->
          {:ok, destination_info}
      end
    end
  end

  defp validate_mutation_target(path, ctx) do
    with {:ok, info} <- FileSystem.authorize(path, :write, ctx),
         :ok <- reject_profile_shadow(info.expanded_path) do
      {:ok, info}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_missing(info, original_path, message) do
    case FileSystem.exists?(info) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, "#{message}: #{original_path}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_regular(info, original_path, message) do
    case FileSystem.regular?(info) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, "#{message}: #{original_path}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_profile_shadow(expanded) do
    if Enum.take(Path.split(expanded), -2) == ["memory", "USER.md"] do
      {:error,
       "USER profile must be managed via user_update and stored at #{Path.join(Workspace.root(), "USER.md")}."}
    else
      :ok
    end
  end

  defp apply_hunks(original_content, hunks) do
    {lines, eof_newline?} = content_to_lines(original_content)

    Enum.reduce_while(hunks, {:ok, lines, 0}, fn hunk, {:ok, current_lines, cursor} ->
      old_lines = Enum.flat_map(hunk, &old_line/1)
      new_lines = Enum.flat_map(hunk, &new_line/1)

      case find_sequence(current_lines, old_lines, cursor) do
        {:ok, index} ->
          next_lines =
            current_lines
            |> Enum.take(index)
            |> Kernel.++(new_lines)
            |> Kernel.++(Enum.drop(current_lines, index + length(old_lines)))

          {:cont, {:ok, next_lines, index + length(new_lines)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, result_lines, _cursor} -> {:ok, lines_to_content(result_lines, eof_newline?)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp old_line(" " <> line), do: [line]
  defp old_line("-" <> line), do: [line]
  defp old_line("+" <> _line), do: []

  defp new_line(" " <> line), do: [line]
  defp new_line("+" <> line), do: [line]
  defp new_line("-" <> _line), do: []

  defp find_sequence(_lines, [], cursor), do: {:ok, cursor}

  defp find_sequence(lines, sequence, cursor) do
    max_index = length(lines) - length(sequence)

    if max_index < cursor do
      {:error, "Patch context mismatch: no matching location found"}
    else
      cursor..max_index
      |> Enum.find(fn index ->
        Enum.slice(lines, index, length(sequence)) == sequence
      end)
      |> case do
        nil -> {:error, "Patch context mismatch: no matching location found"}
        index -> {:ok, index}
      end
    end
  end

  defp content_to_lines(content) do
    eof_newline? = String.ends_with?(content, "\n")

    lines =
      case String.split(content, "\n", trim: false) do
        [""] -> []
        parts when eof_newline? -> Enum.drop(parts, -1)
        parts -> parts
      end

    {lines, eof_newline?}
  end

  defp lines_to_content(lines, eof_newline?) do
    body = Enum.join(lines, "\n")

    cond do
      lines == [] and eof_newline? -> ""
      body == "" -> body
      eof_newline? -> body <> "\n"
      true -> body
    end
  end

  defp apply_operations(prepared_ops) do
    Enum.reduce_while(prepared_ops, {:ok, []}, fn operation, {:ok, applied} ->
      case apply_operation(operation) do
        {:ok, rollback_entry} ->
          {:cont, {:ok, [rollback_entry | applied]}}

        {:error, reason} ->
          rollback(applied)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _applied} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_operation(%{type: :add, path: path, path_info: info, content: content}) do
    with :ok <- FileSystem.write_file(info, content) do
      {:ok, %{undo: :delete, path: path, path_info: info}}
    else
      {:error, reason} -> {:error, "Failed to create #{path}: #{inspect(reason)}"}
    end
  end

  defp apply_operation(%{type: :delete, path: path, path_info: info, original_content: content}) do
    with :ok <- FileSystem.remove(info) do
      {:ok, %{undo: :restore, path: path, path_info: info, content: content}}
    else
      {:error, reason} -> {:error, "Failed to delete #{path}: #{inspect(reason)}"}
    end
  end

  defp apply_operation(%{
         type: :update,
         path: source,
         path_info: source_info,
         destination: source,
         updated_content: content,
         original_content: original_content
       }) do
    with :ok <- FileSystem.write_file(source_info, content) do
      {:ok, %{undo: :restore, path: source, path_info: source_info, content: original_content}}
    else
      {:error, reason} -> {:error, "Failed to update #{source}: #{inspect(reason)}"}
    end
  end

  defp apply_operation(%{
         type: :update,
         path: source,
         path_info: source_info,
         destination: destination,
         destination_info: destination_info,
         updated_content: content,
         original_content: original_content
       }) do
    with :ok <- FileSystem.write_file(destination_info, content) do
      case FileSystem.remove(source_info) do
        :ok ->
          {:ok,
           %{
             undo: :move_restore,
             source: source,
             source_info: source_info,
             destination: destination,
             destination_info: destination_info,
             content: original_content
           }}

        {:error, reason} ->
          rollback_move_destination(destination_info)
          {:error, "Failed to move #{source} to #{destination}: #{inspect(reason)}"}
      end
    else
      {:error, reason} ->
        {:error, "Failed to move #{source} to #{destination}: #{inspect(reason)}"}
    end
  end

  defp rollback_move_destination(destination_info) do
    case FileSystem.remove(destination_info) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp rollback(applied) do
    Enum.each(applied, fn
      %{undo: :delete, path_info: info} ->
        FileSystem.remove(info)

      %{undo: :restore, path_info: info, content: content} ->
        FileSystem.write_file(info, content)

      %{
        undo: :move_restore,
        source_info: source_info,
        destination_info: destination_info,
        content: content
      } ->
        FileSystem.remove(destination_info)
        FileSystem.write_file(source_info, content)
    end)
  end

  defp updated_files(%{type: :update, destination: destination}), do: [destination]
  defp updated_files(_operation), do: []

  defp created_files(%{type: :add, path: path}), do: [path]
  defp created_files(_operation), do: []

  defp deleted_files(%{type: :delete, path: path}), do: [path]
  defp deleted_files(_operation), do: []
end
