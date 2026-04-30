defmodule Nex.Agent.Sandbox.Security do
  @moduledoc """
  Security utilities for the agent.

  Provides path validation, command blacklist validation, and other security checks.
  """

  alias Nex.Agent.Runtime.{Config, Workspace}
  alias Nex.Agent.Sandbox.Approval
  alias Nex.Agent.Sandbox.Approval.Request
  alias Nex.Agent.Sandbox.Policy

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
    "sudo",
    "su"
  ]

  @path_operations ~w(read write list search remove mkdir stat stream)a
  @read_operations ~w(read list search stat stream)a

  @hard_deny_patterns [
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
    {~r/(?:^|[;&|]\s*)(?:sudo|su)\b/i, "Privilege escalation not allowed"}
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
    case authorize_path(path, :read, ctx) do
      {:ok, info} -> {:ok, info.expanded_path}
      {:ask, request} -> {:ask, request}
      {:error, reason} -> {:error, reason}
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
    case authorize_path(path, :write, ctx) do
      {:ok, info} -> {:ok, info.expanded_path}
      {:ask, request} -> {:ask, request}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Authorize a direct filesystem operation against the runtime sandbox policy.
  """
  @spec authorize_path(String.t(), atom(), map() | keyword() | Config.t()) ::
          {:ok, map()} | {:ask, Request.t()} | {:error, String.t()}
  def authorize_path(path, operation, ctx)
      when is_binary(path) and operation in @path_operations do
    expanded = Path.expand(path)
    policy = policy_from_ctx(ctx)

    with :ok <- reject_protected_expanded_path(expanded, policy),
         {:ok, info} <- canonical_path_info(path, expanded),
         :ok <- reject_protected_canonical_path(info, policy) do
      decide_path_access(info, operation, policy, ctx)
    end
  end

  def authorize_path(_path, operation, _ctx) do
    {:error, "Unsupported sandbox path operation: #{inspect(operation)}"}
  end

  defp canonical_path_info(input_path, expanded_path) do
    with {:ok, ancestor, suffix} <- nearest_existing_ancestor(expanded_path),
         {:ok, ancestor_realpath} <- realpath_if_possible(ancestor) do
      canonical_path = join_path([ancestor_realpath | suffix])

      {:ok,
       %{
         input_path: input_path,
         expanded_path: expanded_path,
         canonical_path: canonical_path,
         existing_ancestor: ancestor,
         existing_ancestor_realpath: ancestor_realpath,
         missing_suffix: suffix,
         target_exists?: suffix == []
       }}
    end
  end

  defp nearest_existing_ancestor(path), do: nearest_existing_ancestor(path, [])

  defp nearest_existing_ancestor(path, suffix) do
    cond do
      File.exists?(path) ->
        {:ok, path, suffix}

      Path.dirname(path) == path ->
        {:error, "No existing ancestor for path: #{path}"}

      true ->
        nearest_existing_ancestor(Path.dirname(path), [Path.basename(path) | suffix])
    end
  end

  defp join_path([path]), do: path
  defp join_path(parts), do: Path.join(parts)

  defp realpath_if_possible(path) do
    {:ok, resolve_path_components(Path.expand(path), 0)}
  rescue
    _ -> {:ok, Path.expand(path)}
  end

  defp resolve_path_components(path, depth) when depth > 40, do: Path.expand(path)

  defp resolve_path_components(path, depth) do
    expanded = Path.expand(path)

    case Path.split(expanded) do
      ["/" | parts] -> resolve_parts(parts, "/", depth)
      parts -> resolve_parts(parts, "", depth)
    end
  end

  defp resolve_parts([], current, _depth), do: if(current == "", do: ".", else: current)

  defp resolve_parts([part | rest], current, depth) do
    candidate = Path.join(current, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        resolved_target =
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, Path.dirname(candidate))
          end

        [resolved_target | rest]
        |> join_path()
        |> resolve_path_components(depth + 1)

      {:error, _reason} ->
        resolve_parts(rest, candidate, depth)
    end
  end

  defp decide_path_access(%{} = info, _operation, %Policy{enabled: false}, _ctx),
    do: {:ok, info}

  defp decide_path_access(%{} = info, _operation, %Policy{mode: :danger_full_access}, _ctx),
    do: {:ok, info}

  defp decide_path_access(%{} = info, operation, %Policy{} = policy, ctx) do
    cond do
      denied_by_policy?(info, policy, ctx) ->
        {:error, "Path denied by sandbox policy: #{info.input_path}"}

      allowed_by_policy?(info, operation, policy, ctx) ->
        {:ok, info}

      approved_path?(info, operation, ctx) ->
        {:ok, info}

      true ->
        request_path_approval(info, operation, policy, ctx)
    end
  end

  defp denied_by_policy?(info, policy, ctx) do
    policy
    |> filesystem_entries(ctx)
    |> Enum.any?(fn
      %{access: :none} = entry -> entry_matches_any_authorized_path?(entry, info, ctx)
      _entry -> false
    end)
  end

  defp allowed_by_policy?(info, operation, policy, ctx) do
    policy
    |> filesystem_entries(ctx)
    |> Enum.any?(fn
      %{access: access} = entry when access in [:read, :write] ->
        access_permits_operation?(access, operation) and
          entry_matches_authorized_path?(entry, info, ctx)

      _entry ->
        false
    end)
  end

  defp access_permits_operation?(:write, _operation), do: true
  defp access_permits_operation?(:read, operation), do: operation in @read_operations
  defp access_permits_operation?(_access, _operation), do: false

  defp filesystem_entries(%Policy{} = policy, ctx) do
    case env_allowed_roots() do
      [] ->
        policy.filesystem ++ extra_filesystem_entries(ctx)

      roots ->
        path_entries(:none, policy.protected_paths) ++
          path_entries(:write, roots) ++
          extra_filesystem_entries(ctx)
    end
  end

  defp extra_filesystem_entries(ctx) do
    path_entries(:write, explicit_allowed_roots(ctx))
  end

  defp path_entries(access, paths) do
    paths
    |> normalize_roots()
    |> Enum.map(&%{path: {:path, &1}, access: access})
  end

  defp env_allowed_roots do
    case System.get_env("NEX_ALLOWED_ROOTS") do
      nil -> []
      paths -> String.split(paths, ":")
    end
  end

  defp entry_matches_authorized_path?(entry, info, ctx) do
    entry
    |> entry_roots(ctx)
    |> Enum.any?(fn %{expanded: root, canonical: canonical_root} ->
      path_within_root?(info.expanded_path, root) and
        path_within_root?(info.canonical_path, canonical_root)
    end)
  end

  defp entry_matches_any_authorized_path?(entry, info, ctx) do
    paths = [
      info.expanded_path,
      info.canonical_path,
      info.existing_ancestor,
      info.existing_ancestor_realpath
    ]

    entry
    |> entry_roots(ctx)
    |> Enum.any?(fn %{expanded: root, canonical: canonical_root} ->
      Enum.any?(paths, &(path_within_root?(&1, root) or path_within_root?(&1, canonical_root)))
    end)
  end

  defp entry_roots(%{path: path_ref}, ctx) do
    path_ref
    |> resolve_path_ref(ctx)
    |> Enum.flat_map(fn root ->
      expanded = Path.expand(root)
      {:ok, canonical} = realpath_if_possible(expanded)
      [%{expanded: expanded, canonical: canonical}]
    end)
  end

  defp resolve_path_ref({:path, path}, _ctx) when is_binary(path), do: [path]

  defp resolve_path_ref({:special, :workspace}, ctx) do
    case workspace_from_ctx(ctx) do
      workspace when is_binary(workspace) and workspace != "" -> [workspace]
      _ -> []
    end
  end

  defp resolve_path_ref({:special, :minimal}, _ctx) do
    [Application.get_env(:nex_agent, :repo_root, File.cwd!())]
  end

  defp resolve_path_ref({:special, :tmp}, _ctx), do: [System.tmp_dir!()]
  defp resolve_path_ref({:special, :slash_tmp}, _ctx), do: ["/tmp"]
  defp resolve_path_ref(_path_ref, _ctx), do: []

  defp path_within_root?(path, root) when is_binary(path) and is_binary(root) do
    path == root or root == "/" or String.starts_with?(path, root <> "/")
  end

  defp path_within_root?(_path, _root), do: false

  defp reject_protected_expanded_path(path, %Policy{} = policy) do
    cond do
      path_matches_protected_path?(path, policy.protected_paths) ->
        {:error, "Path is hard-denied by sandbox policy: #{path}"}

      path_contains_protected_name?(path, policy.protected_names) ->
        {:error, "Path contains protected name blocked by sandbox policy: #{path}"}

      true ->
        :ok
    end
  end

  defp reject_protected_canonical_path(%{} = info, %Policy{} = policy) do
    [info.canonical_path, info.existing_ancestor_realpath]
    |> Enum.find(&path_matches_protected_path?(&1, policy.protected_paths))
    |> case do
      nil -> :ok
      path -> {:error, "Path is hard-denied by sandbox policy: #{path}"}
    end
  end

  defp path_matches_protected_path?(path, protected_paths) when is_binary(path) do
    Enum.any?(protected_paths, fn protected ->
      path_within_root?(path, protected)
    end)
  end

  defp path_matches_protected_path?(_path, _protected_paths), do: false

  defp path_contains_protected_name?(path, protected_names) do
    names = MapSet.new(protected_names || [])

    path
    |> Path.split()
    |> Enum.any?(&MapSet.member?(names, &1))
  end

  defp approved_path?(info, operation, ctx) do
    with true <- approval_server_available?(ctx),
         request <- path_approval_request(info, operation, ctx) do
      Approval.approved?(
        request.workspace,
        request.session_key,
        request,
        approval_opts(ctx)
      )
    else
      _ -> false
    end
  end

  defp request_path_approval(info, operation, policy, ctx) do
    case approval_default(policy) do
      "allow" ->
        {:ok, info}

      "deny" ->
        {:error, path_not_allowed_message(policy, ctx)}

      _ ->
        do_request_path_approval(info, operation, policy, ctx)
    end
  end

  defp do_request_path_approval(info, operation, policy, ctx) do
    request = path_approval_request(info, operation, ctx)

    cond do
      ctx_value(ctx, :approval_mode) == :defer ->
        {:ask, request}

      not interactive_approval_context?(request) ->
        {:error, path_not_allowed_message(policy, ctx)}

      not approval_server_available?(ctx) ->
        {:error, path_not_allowed_message(policy, ctx)}

      true ->
        case Approval.request(request, approval_opts(ctx)) do
          {:ok, :approved} -> {:ok, info}
          {:error, :denied} -> {:error, "Sandbox approval denied for path: #{info.input_path}"}
          {:error, {:cancelled, reason}} -> {:error, "Sandbox approval cancelled: #{reason}"}
          {:error, reason} -> {:error, "Sandbox approval failed: #{inspect(reason)}"}
        end
    end
  end

  defp approval_default(%Policy{raw: %{} = raw}) do
    raw
    |> Map.get("approval", %{})
    |> case do
      %{} = approval -> Map.get(approval, "default", "ask")
      _ -> "ask"
    end
  end

  defp path_approval_request(info, operation, ctx) do
    grant_operation = grant_operation(operation)
    grant_key = path_grant_key(grant_operation, :exact, info.canonical_path)
    parent = Path.dirname(info.canonical_path)

    Request.new(%{
      kind: :path,
      operation: grant_operation,
      subject: info.canonical_path,
      description: "Allow #{grant_operation} access to #{info.canonical_path}",
      grant_key: grant_key,
      grant_options: [
        %{
          "level" => "exact",
          "grant_key" => grant_key,
          "subject" => info.canonical_path
        },
        %{
          "level" => "similar",
          "scope" => "similar",
          "grant_key" => path_grant_key(grant_operation, :directory, parent),
          "subject" => "#{grant_operation} under #{parent}"
        }
      ],
      workspace: workspace_from_ctx(ctx) || Workspace.root(),
      session_key: session_key_from_ctx(ctx),
      channel: ctx_value(ctx, :channel),
      chat_id: ctx_value(ctx, :chat_id),
      authorized_actor: actor_from_ctx(ctx)
    })
  end

  defp grant_operation(operation) when operation in @read_operations, do: :read
  defp grant_operation(_operation), do: :write

  defp path_grant_key(operation, level, subject) do
    digest =
      subject
      |> to_string()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "path:#{operation}:#{level}:#{digest}"
  end

  defp interactive_approval_context?(%Request{} = request) do
    present?(request.channel) and present?(request.chat_id)
  end

  defp approval_server_available?(ctx) do
    case ctx_value(ctx, :approval_server) do
      pid when is_pid(pid) -> Process.alive?(pid)
      name when is_atom(name) and not is_nil(name) -> Process.whereis(name) != nil
      _ -> Process.whereis(Approval) != nil
    end
  end

  defp approval_opts(ctx) do
    case ctx_value(ctx, :approval_server) do
      nil -> []
      server -> [server: server]
    end
  end

  defp session_key_from_ctx(ctx) do
    case ctx_value(ctx, :session_key) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        channel = ctx_value(ctx, :channel)
        chat_id = ctx_value(ctx, :chat_id)

        if present?(channel) and present?(chat_id), do: "#{channel}:#{chat_id}", else: "default"
    end
  end

  defp actor_from_ctx(ctx) do
    case ctx_value(ctx, :user_id) || ctx_value(ctx, :actor) do
      nil -> nil
      value -> %{"id" => to_string(value)}
    end
  end

  defp path_not_allowed_message(policy, ctx) do
    roots =
      policy
      |> filesystem_entries(ctx)
      |> Enum.reject(&(&1.access == :none))
      |> Enum.flat_map(&entry_roots(&1, ctx))
      |> Enum.map(& &1.expanded)
      |> Enum.uniq()

    "Path not within allowed roots. Allowed: #{Enum.join(roots, ", ")}"
  end

  defp policy_from_ctx(ctx) do
    case ctx_value(ctx, :sandbox_policy) || snapshot_sandbox(ctx_value(ctx, :runtime_snapshot)) do
      %Policy{} = policy -> policy
      _ -> Config.sandbox_runtime(config_from_ctx(ctx), workspace: workspace_from_ctx(ctx))
    end
  end

  defp workspace_from_ctx(ctx) do
    ctx_value(ctx, :workspace) ||
      snapshot_workspace(ctx_value(ctx, :runtime_snapshot)) ||
      configured_workspace(config_from_ctx(ctx)) ||
      Workspace.root()
  end

  defp snapshot_sandbox(%{sandbox: %Policy{} = policy}), do: policy
  defp snapshot_sandbox(%{"sandbox" => %Policy{} = policy}), do: policy
  defp snapshot_sandbox(_snapshot), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

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

      true ->
        check_hard_deny_patterns(sanitized_command)
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

  defp check_hard_deny_patterns(command) do
    case Enum.find_value(@hard_deny_patterns, fn {pattern, reason} ->
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
    @blocked_commands
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
    default_allowed_roots() ++
      workspace_roots(ctx) ++
      config_allowed_roots(ctx) ++
      explicit_allowed_roots(ctx)
  end

  defp workspace_roots(ctx) do
    case ctx_value(ctx, :workspace) || snapshot_workspace(ctx_value(ctx, :runtime_snapshot)) ||
           configured_workspace(config_from_ctx(ctx)) do
      workspace when is_binary(workspace) and workspace != "" -> [workspace]
      _ -> []
    end
  end

  defp config_allowed_roots(ctx), do: Config.file_access_allowed_roots(config_from_ctx(ctx))

  defp explicit_allowed_roots(ctx) do
    ctx
    |> ctx_value(:extra_allowed_roots)
    |> List.wrap()
  end

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
