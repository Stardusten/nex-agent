defmodule Nex.Agent.Tasks.Store do
  @moduledoc false

  alias Nex.Agent.Runtime.Workspace

  @tasks_file "tasks.json"
  @legacy_file "cron_jobs.json"

  @spec path(keyword()) :: String.t()
  def path(opts \\ []) do
    opts
    |> Workspace.tasks_dir()
    |> Path.join(@tasks_file)
  end

  @spec migrate_legacy!(keyword()) :: :ok
  def migrate_legacy!(opts \\ []) do
    tasks_path = path(opts)
    legacy_path = legacy_path(opts)

    cond do
      File.exists?(tasks_path) ->
        :ok

      not File.exists?(legacy_path) ->
        :ok

      true ->
        File.mkdir_p!(Path.dirname(tasks_path))
        File.rename!(legacy_path, tasks_path)
        :ok
    end
  end

  @spec read_raw(keyword()) :: [map()]
  def read_raw(opts \\ []) do
    migrate_legacy!(opts)

    case File.read(path(opts)) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) -> Enum.filter(list, &is_map/1)
          _ -> []
        end

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        []
    end
  end

  defp legacy_path(opts) do
    opts
    |> Workspace.tasks_dir()
    |> Path.join(@legacy_file)
  end
end
