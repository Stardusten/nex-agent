defmodule Nex.Agent.Sandbox.Backends.Seatbelt do
  @moduledoc """
  macOS Seatbelt backend implemented through `/usr/bin/sandbox-exec`.
  """

  @behaviour Nex.Agent.Sandbox.Backend

  alias Nex.Agent.Sandbox.{Command, Policy}

  @seatbelt "/usr/bin/sandbox-exec"

  @impl true
  def name, do: :seatbelt

  @impl true
  def available?, do: File.regular?(@seatbelt)

  @impl true
  def wrap(%Command{} = command, %Policy{} = policy) do
    profile = profile(command, policy)

    {:ok,
     %Command{
       command
       | program: @seatbelt,
         args: ["-p", profile, "--", command.program | command.args],
         metadata: Map.put(command.metadata || %{}, :sandbox_backend, :seatbelt)
     }}
  end

  @spec profile(Command.t(), Policy.t()) :: String.t()
  def profile(%Command{} = command, %Policy{} = policy) do
    [
      base_policy(),
      read_policy(command, policy),
      write_policy(command, policy),
      network_policy(policy)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp base_policy do
    """
    (version 1)
    (deny default)
    (allow process-exec)
    (allow process-fork)
    (allow signal (target same-sandbox))
    (allow process-info* (target same-sandbox))
    (allow sysctl*)
    (allow mach-lookup)
    (allow iokit-open)
    (allow ipc-posix-sem)
    (allow pseudo-tty)
    (allow file-read* file-write* file-ioctl (literal "/dev/ptmx"))
    (allow file-read* file-write* (literal "/dev/null"))
    (allow file-read* (literal "/dev/random"))
    (allow file-read* (literal "/dev/urandom"))
    """
    |> String.trim()
  end

  defp read_policy(%Command{} = command, %Policy{} = policy) do
    exclusions =
      policy
      |> denied_paths(command)
      |> Enum.flat_map(&path_variants/1)
      |> Enum.uniq()

    cond do
      exclusions == [] ->
        "(allow file-read*)"

      true ->
        require_parts =
          ["(subpath \"/\")" | Enum.flat_map(exclusions, &path_exclusion_filters/1)]
          |> Enum.join(" ")

        "(allow file-read* (require-all #{require_parts}))"
    end
  end

  defp write_policy(%Command{} = command, %Policy{} = policy) do
    roots =
      policy
      |> filesystem_roots(command, :write)
      |> Enum.flat_map(&path_variants/1)
      |> Enum.uniq()

    exclusions =
      policy
      |> denied_paths(command)
      |> Enum.flat_map(&path_variants/1)
      |> Enum.uniq()

    protected_names = policy.protected_names || []

    roots
    |> Enum.map(fn root ->
      filters =
        ["(subpath #{sbpl_string(root)})"] ++
          Enum.flat_map(exclusions, &path_exclusion_filters/1) ++
          protected_name_filters(root, protected_names)

      "(allow file-write* (require-all #{Enum.join(filters, " ")}))"
    end)
    |> Enum.join("\n")
  end

  defp network_policy(%Policy{network: :enabled}) do
    """
    (allow network-outbound)
    (allow network-inbound)
    (allow network-bind)
    """
    |> String.trim()
  end

  defp network_policy(%Policy{}), do: ""

  defp denied_paths(%Policy{} = policy, %Command{} = command) do
    explicit_denies =
      policy.filesystem
      |> Enum.filter(&(&1.access == :none))
      |> Enum.flat_map(&resolve_path_ref(&1.path, command))

    policy.protected_paths ++ explicit_denies
  end

  defp filesystem_roots(%Policy{} = policy, %Command{} = command, access) do
    policy.filesystem
    |> Enum.filter(fn
      %{access: ^access} -> true
      _entry -> false
    end)
    |> Enum.flat_map(&resolve_path_ref(&1.path, command))
  end

  defp resolve_path_ref({:path, path}, _command) when is_binary(path), do: [path]

  defp resolve_path_ref({:special, :workspace}, %Command{cwd: cwd, metadata: metadata}) do
    workspace =
      Map.get(metadata || %{}, :workspace) ||
        Map.get(metadata || %{}, "workspace") ||
        cwd

    [workspace]
  end

  defp resolve_path_ref({:special, :minimal}, _command) do
    [Application.get_env(:nex_agent, :repo_root, File.cwd!())]
  end

  defp resolve_path_ref({:special, :tmp}, _command), do: [System.tmp_dir!()]
  defp resolve_path_ref({:special, :slash_tmp}, _command), do: ["/tmp"]
  defp resolve_path_ref(_path_ref, _command), do: []

  defp path_variants(path) when is_binary(path) do
    expanded = Path.expand(path)

    variants =
      [expanded, realpath_or_nearest(expanded)]
      |> Enum.reject(&is_nil/1)

    tmp_aliases =
      variants
      |> Enum.flat_map(fn
        "/tmp/" <> rest -> ["/private/tmp/" <> rest]
        "/private/tmp/" <> rest -> ["/tmp/" <> rest]
        "/tmp" -> ["/private/tmp"]
        "/private/tmp" -> ["/tmp"]
        _path -> []
      end)

    (variants ++ tmp_aliases)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp path_variants(_path), do: []

  defp realpath_or_nearest(path) do
    cond do
      File.exists?(path) ->
        resolve_path_components(path)

      Path.dirname(path) == path ->
        nil

      true ->
        parent = Path.dirname(path)

        case realpath_or_nearest(parent) do
          nil -> nil
          real_parent -> Path.join(real_parent, Path.relative_to(path, parent))
        end
    end
  end

  defp resolve_path_components(path), do: resolve_path_components(Path.expand(path), 0)

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
        |> Path.join()
        |> resolve_path_components(depth + 1)

      {:error, _reason} ->
        resolve_parts(rest, candidate, depth)
    end
  end

  defp path_exclusion_filters(path) do
    [
      "(require-not (literal #{sbpl_string(path)}))",
      "(require-not (subpath #{sbpl_string(path)}))"
    ]
  end

  defp protected_name_filters(_root, []), do: []

  defp protected_name_filters(root, names) do
    Enum.map(names, fn name ->
      regex =
        root
        |> trim_trailing_slash()
        |> Regex.escape()
        |> then(fn
          "/" -> "^/#{Regex.escape(name)}(/.*)?$"
          escaped_root -> "^#{escaped_root}/#{Regex.escape(name)}(/.*)?$"
        end)
        |> String.replace("\"", "\\\"")

      "(require-not (regex #\"#{regex}\"))"
    end)
  end

  defp trim_trailing_slash("/"), do: "/"

  defp trim_trailing_slash(path) do
    String.trim_trailing(path, "/")
  end

  defp sbpl_string(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end
end
