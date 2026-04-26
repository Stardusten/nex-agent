defmodule Nex.Agent.Runtime.Watcher do
  @moduledoc """
  Minimal polling watcher for runtime inputs.
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Config, Runtime, Skills, Workspace}
  alias Nex.Agent.Tool.Registry, as: ToolRegistry

  defstruct [
    :workspace,
    :config_path,
    :poll_interval_ms,
    :runtime_reload_fun,
    :skills_reload_fun,
    :tools_reload_fun,
    snapshot: %{}
  ]

  @default_poll_interval_ms 1_000
  @workspace_files ~w(AGENTS.md IDENTITY.md SOUL.md USER.md TOOLS.md memory/MEMORY.md hooks/hooks.json)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    workspace = Keyword.get(opts, :workspace) || Workspace.root(opts)
    config_path = Keyword.get(opts, :config_path) || Config.config_path(opts)

    state = %__MODULE__{
      workspace: workspace,
      config_path: config_path,
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      runtime_reload_fun: Keyword.get(opts, :runtime_reload_fun, &Runtime.reload/1),
      skills_reload_fun: Keyword.get(opts, :skills_reload_fun, &Skills.reload/0),
      tools_reload_fun: Keyword.get(opts, :tools_reload_fun, &ToolRegistry.reload/0)
    }

    state = %{state | snapshot: scan_inputs(state)}
    schedule_poll(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_snapshot = scan_inputs(state)
    changed_paths = changed_paths(state.snapshot, new_snapshot)

    if changed_paths != [] do
      reload_runtime(state, changed_paths)
    end

    state = %{state | snapshot: new_snapshot}
    schedule_poll(state)
    {:noreply, state}
  end

  defp reload_runtime(state, changed_paths) do
    if Enum.any?(changed_paths, &skills_path?/1), do: state.skills_reload_fun.()
    if Enum.any?(changed_paths, &tools_path?/1), do: state.tools_reload_fun.()

    case state.runtime_reload_fun.(workspace: state.workspace, changed_paths: changed_paths) do
      {:ok, _snapshot} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Runtime.Watcher] Runtime reload failed: #{inspect(reason)}")
    end
  end

  defp schedule_poll(%__MODULE__{poll_interval_ms: interval}) when interval in [nil, false] do
    :ok
  end

  defp schedule_poll(%__MODULE__{poll_interval_ms: interval}) do
    Process.send_after(self(), :poll, interval)
    :ok
  end

  defp scan_inputs(state) do
    state
    |> watched_paths()
    |> Enum.map(fn path -> {path, path_signature(path)} end)
    |> Map.new()
  end

  defp watched_paths(%__MODULE__{} = state) do
    direct_paths =
      [state.config_path] ++ Enum.map(@workspace_files, &Path.join(state.workspace, &1))

    recursive_paths =
      [Path.join(state.workspace, "skills"), Path.join(state.workspace, "tools")]
      |> Enum.flat_map(&recursive_files/1)

    (direct_paths ++ recursive_paths)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp recursive_files(path) do
    if File.dir?(path) do
      path
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
    else
      []
    end
  end

  defp path_signature(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {stat.mtime, stat.size}
      {:error, reason} -> {:missing, reason}
    end
  end

  defp changed_paths(old_snapshot, new_snapshot) do
    keys =
      old_snapshot
      |> Map.keys()
      |> Kernel.++(Map.keys(new_snapshot))
      |> Enum.uniq()

    keys
    |> Enum.filter(&(Map.get(old_snapshot, &1) != Map.get(new_snapshot, &1)))
    |> Enum.sort()
  end

  defp skills_path?(path), do: path_segment?(path, "skills")
  defp tools_path?(path), do: path_segment?(path, "tools")

  defp path_segment?(path, segment) do
    path
    |> Path.split()
    |> Enum.member?(segment)
  end
end
