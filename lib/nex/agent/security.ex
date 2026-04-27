defmodule Nex.Agent.Security do
  @moduledoc """
  Security utilities for the agent.

  Provides path validation, command blacklist validation, and other security checks.
  """

  alias Nex.Agent.Config

  @blocked_commands [
    "mkfs",
    "fdisk",
    "parted",
    "diskpart",
    "dd",
    "shutdown",
    "reboot",
    "poweroff",
    "halt",
    "nc",
    "netcat",
    "ncat",
    "sudo",
    "su"
  ]

  @blocked_shells ~w(bash sh zsh fish csh tcsh dash ksh)

  @dangerous_patterns [
    {~r/\brm\s+(-[^\s]*\s+)*\/(bin|sbin|usr|etc|var|boot|lib|sys|proc)\b/i,
     "Deleting system directories not allowed"},
    {~r/\brm\s+(-[^\s]*\s+)*\/\s*$/i, "Deleting from root not allowed"},
    {~r/\brm\s+(-[^\s]*\s+)*~\/?\s*$/i, "Deleting entire home directory not allowed"},
    {~r/\bdel\s+\/[fq]\b/i, "Forced file deletion not allowed"},
    {~r/\brmdir\s+\/s\b/i, "Recursive directory deletion not allowed"},
    {~r/(?:^|[;&|]\s*)format\b/i, "Disk formatting not allowed"},
    {~r/\b(mkfs|diskpart)\b/i, "Disk operations not allowed"},
    {~r/\bdd\s+if=/i, "Raw disk copy not allowed"},
    {~r/>\s*\/dev\/sd/i, "Writing to block devices not allowed"},
    {~r/\b(shutdown|reboot|poweroff)\b/i, "System power control not allowed"},
    {~r/:\(\)\s*\{.*\};\s*:/, "Fork bomb not allowed"},
    {~r/[;&|]\s*(?:bash|sh|zsh|fish|csh|tcsh|dash|ksh)\s+-[ic]/i, "Shell injection not allowed"},
    {~r/`[^`]+`/, "Command substitution not allowed"},
    {~r/\$\([^)]+\)/, "Command substitution not allowed"},
    {~r/\b(env|xargs|exec|nice|timeout)\s+.*\b(bash|sh|zsh|fish|csh|tcsh|dash|ksh)\b/i,
     "Shell command escape not allowed"},
    {~r/\bpython\b.*-c\b/i, "Python command execution not allowed"},
    {~r/\bperl\b.*-e\b/i, "Perl command execution not allowed"},
    {~r/\bruby\b.*-e\b/i, "Ruby command execution not allowed"},
    {~r/\bnode\b.*-e\b/i, "Node.js command execution not allowed"},
    {~r/\bphp\b.*-r\b/i, "PHP command execution not allowed"},
    {~r/\b(os\.system|subprocess|eval\(|exec\(|import\s+os)\b/i,
     "Python system calls not allowed"}
  ]

  @doc """
  Get the list of allowed root directories for file access.
  """
  @spec allowed_roots(map() | keyword() | Config.t()) :: [String.t()]
  def allowed_roots(ctx) do
    case System.get_env("NEX_ALLOWED_ROOTS") do
      nil ->
        ctx
        |> configured_allowed_roots()
        |> normalize_roots()

      paths ->
        paths
        |> String.split(":")
        |> normalize_roots()
    end
  end

  @doc """
  Validate that a path is within allowed roots.

  Returns {:ok, expanded_path} if valid, {:error, reason} if not.
  """
  @spec validate_path(String.t(), map() | keyword() | Config.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_path(path, ctx) do
    expanded = Path.expand(path)
    roots = allowed_roots(ctx)

    if String.contains?(path, "..") and not safe_traversal?(path, roots) do
      {:error, "Path traversal not allowed: #{path}"}
    else
      with true <- path_within_allowed_roots?(expanded, roots),
           {:ok, real_path} <- realpath_if_possible(expanded),
           true <- path_within_allowed_roots?(real_path, roots) do
        {:ok, expanded}
      else
        false ->
          {:error, "Path not within allowed roots. Allowed: #{Enum.join(roots, ", ")}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Validate a write target, including files that do not exist yet.

  For non-existent paths, validation is anchored on the nearest existing ancestor
  so symlink escapes still fail the allowed-roots check.
  """
  @spec validate_write_path(String.t(), map() | keyword() | Config.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_write_path(path, ctx) do
    expanded = Path.expand(path)
    roots = allowed_roots(ctx)

    if String.contains?(path, "..") and not safe_traversal?(path, roots) do
      {:error, "Path traversal not allowed: #{path}"}
    else
      with true <- path_within_allowed_roots?(expanded, roots),
           {:ok, ancestor} <- nearest_existing_ancestor(expanded),
           {:ok, real_ancestor} <- realpath_if_possible(ancestor),
           true <- path_within_allowed_roots?(real_ancestor, roots) do
        {:ok, expanded}
      else
        false ->
          {:error, "Path not within allowed roots. Allowed: #{Enum.join(roots, ", ")}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp safe_traversal?(path, roots) do
    expanded = Path.expand(path)

    path_within_allowed_roots?(expanded, roots) and
      not symlink_escapes_to_forbidden_path?(expanded, roots)
  end

  defp path_within_allowed_roots?(expanded_path, roots) do
    Enum.any?(roots, fn root ->
      expanded_path == root or root == "/" or String.starts_with?(expanded_path, root <> "/")
    end)
  end

  defp symlink_escapes_to_forbidden_path?(path, roots) do
    case File.read_link(path) do
      {:ok, target} ->
        expanded_target = Path.expand(target)
        not path_within_allowed_roots?(expanded_target, roots)

      {:error, _} ->
        false
    end
  rescue
    _ -> false
  end

  defp nearest_existing_ancestor(path) do
    parent = Path.dirname(path)

    cond do
      File.exists?(path) ->
        {:ok, path}

      parent == path ->
        {:error, "No existing ancestor for path: #{path}"}

      true ->
        nearest_existing_ancestor(parent)
    end
  end

  defp realpath_if_possible(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, resolved} -> {:ok, List.to_string(resolved)}
      {:error, _reason} -> {:ok, Path.expand(path)}
    end
  end

  @doc """
  Validate a command against the blacklist.

  Returns :ok if allowed, {:error, reason} if not.
  """
  @spec validate_command(String.t()) :: :ok | {:error, String.t()}
  def validate_command("") do
    :ok
  end

  def validate_command(command) do
    normalized_command = command |> String.trim() |> String.downcase()
    sanitized_command = strip_quoted_segments(normalized_command)
    sanitized_command = remove_inline_comments(sanitized_command)

    first_token = normalized_command |> String.split(~r/\s+/, parts: 2) |> hd()
    base_cmd = extract_base_command(first_token)

    cond do
      base_cmd in @blocked_commands ->
        {:error, "Command blocked: #{base_cmd}"}

      base_cmd in @blocked_shells ->
        {:error, "Shell invocation blocked: #{base_cmd}"}

      true ->
        check_dangerous_patterns(sanitized_command)
    end
  end

  defp extract_base_command(token) do
    token
    |> String.split("/")
    |> List.last()
    |> String.split("@")
    |> List.first()
  end

  defp remove_inline_comments(command) do
    command
    |> String.replace(~r/\s+#.*$/, "")
  end

  defp check_dangerous_patterns(command) do
    case Enum.find_value(@dangerous_patterns, fn {pattern, reason} ->
           if Regex.match?(pattern, command), do: reason
         end) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  @doc """
  Get the list of blocked commands.
  """
  @spec blocked_commands() :: [String.t()]
  def blocked_commands do
    @blocked_commands ++ @blocked_shells
  end

  defp strip_quoted_segments(command) do
    command
    |> String.replace(~r/'[^']*'/, "''")
    |> String.replace(~r/"[^"]*"/, "\"\"")
  end

  defp default_allowed_roots do
    [
      File.cwd!(),
      Path.join(System.get_env("HOME", "~"), ".nex/agent"),
      Path.join(System.get_env("HOME", "~"), "github"),
      "/tmp"
    ]
  end

  defp configured_allowed_roots(ctx) do
    default_allowed_roots() ++ workspace_roots(ctx) ++ config_allowed_roots(ctx)
  end

  defp workspace_roots(ctx) do
    case ctx_value(ctx, :workspace) || snapshot_workspace(ctx_value(ctx, :runtime_snapshot)) ||
           configured_workspace(config_from_ctx(ctx)) do
      workspace when is_binary(workspace) and workspace != "" -> [workspace]
      _ -> []
    end
  end

  defp config_allowed_roots(ctx), do: Config.file_access_allowed_roots(config_from_ctx(ctx))

  defp config_from_ctx(%Config{} = config), do: config

  defp config_from_ctx(ctx) do
    case ctx_value(ctx, :config) || snapshot_config(ctx_value(ctx, :runtime_snapshot)) do
      %Config{} = config -> config
      _ -> nil
    end
  end

  defp snapshot_config(%{config: %Config{} = config}), do: config
  defp snapshot_config(%{"config" => %Config{} = config}), do: config
  defp snapshot_config(_snapshot), do: nil

  defp snapshot_workspace(%{workspace: workspace}) when is_binary(workspace), do: workspace
  defp snapshot_workspace(%{"workspace" => workspace}) when is_binary(workspace), do: workspace
  defp snapshot_workspace(_snapshot), do: nil

  defp configured_workspace(%Config{} = config), do: Config.configured_workspace(config)
  defp configured_workspace(_config), do: nil

  defp ctx_value(ctx, key) when is_list(ctx),
    do: Keyword.get(ctx, key) || Keyword.get(ctx, to_string(key))

  defp ctx_value(ctx, key) when is_map(ctx), do: Map.get(ctx, key) || Map.get(ctx, to_string(key))
  defp ctx_value(_ctx, _key), do: nil

  defp normalize_roots(roots) do
    roots
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end
end
