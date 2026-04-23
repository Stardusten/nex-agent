defmodule Nex.Agent.SelfUpdate.ReleaseStore do
  @moduledoc false

  alias Nex.Agent.CodeUpgrade

  @type release_file :: %{
          id: String.t(),
          parent_release_id: String.t() | nil,
          timestamp: String.t(),
          reason: String.t(),
          files: [map()],
          modules: [String.t()],
          tests: [map()],
          status: String.t()
        }

  @type release_state :: %{
          releases: [release_file()],
          releases_by_id: %{optional(String.t()) => release_file()},
          current_event_release: release_file() | nil,
          current_effective_release: release_file() | nil,
          previous_rollback_target: release_file() | nil,
          rollback_candidates: [release_file()],
          rollback_candidate_ids: MapSet.t(String.t())
        }

  @spec root_dir() :: String.t()
  def root_dir do
    Path.join(CodeUpgrade.repo_root(), ".nex_self_update")
  end

  @spec releases_dir() :: String.t()
  def releases_dir, do: Path.join(root_dir(), "releases")

  @spec snapshots_dir() :: String.t()
  def snapshots_dir, do: Path.join(root_dir(), "snapshots")

  @spec applied_dir() :: String.t()
  def applied_dir, do: Path.join(root_dir(), "applied")

  @spec ensure_layout() :: :ok
  def ensure_layout do
    File.mkdir_p!(releases_dir())
    File.mkdir_p!(snapshots_dir())
    File.mkdir_p!(applied_dir())
    :ok
  end

  @spec new_release_id() :: String.t()
  def new_release_id do
    timestamp =
      System.system_time(:microsecond)
      |> Integer.to_string()

    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{timestamp}-#{suffix}"
  end

  @spec new_timestamp() :: String.t()
  def new_timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
  end

  @spec save_snapshot(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def save_snapshot(release_id, relative_path, content)
      when is_binary(release_id) and is_binary(relative_path) and is_binary(content) do
    snapshot_path = snapshot_path(release_id, relative_path)
    File.mkdir_p!(Path.dirname(snapshot_path))
    File.write(snapshot_path, content)
  end

  @spec read_snapshot(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_snapshot(release_id, relative_path)
      when is_binary(release_id) and is_binary(relative_path) do
    File.read(snapshot_path(release_id, relative_path))
  end

  @spec save_applied(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def save_applied(release_id, relative_path, content)
      when is_binary(release_id) and is_binary(relative_path) and is_binary(content) do
    applied_path = applied_path(release_id, relative_path)
    File.mkdir_p!(Path.dirname(applied_path))
    File.write(applied_path, content)
  end

  @spec read_applied(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_applied(release_id, relative_path)
      when is_binary(release_id) and is_binary(relative_path) do
    File.read(applied_path(release_id, relative_path))
  end

  @spec save_release(map()) :: :ok | {:error, term()}
  def save_release(%{"id" => id} = release) do
    ensure_layout()
    File.write(release_path(id), Jason.encode!(release, pretty: true))
  end

  def save_release(%{id: id} = release) do
    ensure_layout()
    File.write(release_path(id), Jason.encode!(release, pretty: true))
  end

  @spec load_release(String.t()) :: {:ok, release_file()} | {:error, term()}
  def load_release(release_id) when is_binary(release_id) do
    with {:ok, body} <- File.read(release_path(release_id)),
         {:ok, release} <- Jason.decode(body) do
      {:ok, release}
    end
  end

  @spec list_releases() :: [release_file()]
  def list_releases do
    ensure_layout()

    releases_dir()
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(&release_path_from_name/1)
    |> Enum.map(&load_release_file/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(
      fn release ->
        {Map.get(release, "timestamp", ""), Map.get(release, "id", "")}
      end,
      :desc
    )
  end

  @spec release_state() :: release_state()
  def release_state do
    releases = list_releases()
    releases_by_id = Map.new(releases, &{Map.get(&1, "id"), &1})
    current_event_release = List.first(releases)
    current_effective_release = resolve_effective_release(current_event_release, releases_by_id)

    rollback_candidates =
      current_effective_release
      |> effective_lineage(releases_by_id)
      |> Enum.drop(1)

    %{
      releases: releases,
      releases_by_id: releases_by_id,
      current_event_release: current_event_release,
      current_effective_release: current_effective_release,
      previous_rollback_target: List.first(rollback_candidates),
      rollback_candidates: rollback_candidates,
      rollback_candidate_ids:
        rollback_candidates
        |> Enum.map(&Map.get(&1, "id"))
        |> MapSet.new()
    }
  end

  @spec history_view() :: map()
  def history_view do
    state = release_state()
    current_effective_id = release_id(state.current_effective_release)

    %{
      status: :ok,
      current_effective_release: current_effective_id,
      releases:
        Enum.map(state.releases, fn release ->
          %{
            id: Map.get(release, "id"),
            status: Map.get(release, "status"),
            reason: Map.get(release, "reason"),
            timestamp: Map.get(release, "timestamp"),
            parent_release_id: Map.get(release, "parent_release_id"),
            effective: Map.get(release, "id") == current_effective_id,
            rollback_candidate:
              MapSet.member?(state.rollback_candidate_ids, Map.get(release, "id"))
          }
        end)
    }
  end

  @spec resolve_rollback_target(String.t() | nil) ::
          {:ok,
           %{
             restore_source: {:snapshot | :applied, release_file()},
             target_release_id: String.t() | nil
           }}
          | {:error, String.t()}
  def resolve_rollback_target(target \\ nil) do
    state = release_state()
    current_effective_id = release_id(state.current_effective_release)

    case target do
      nil ->
        resolve_previous_rollback_target(state)

      "previous" ->
        resolve_previous_rollback_target(state)

      release_id when is_binary(release_id) ->
        cond do
          not Map.has_key?(state.releases_by_id, release_id) ->
            {:error, "Rollback target release not found: #{release_id}"}

          release_id == current_effective_id ->
            {:error, "Already at target release: #{release_id}"}

          not MapSet.member?(state.rollback_candidate_ids, release_id) ->
            {:error,
             "Rollback target is not reachable from current effective release lineage: #{release_id}"}

          true ->
            {:ok,
             %{
               restore_source: {:applied, Map.fetch!(state.releases_by_id, release_id)},
               target_release_id: release_id
             }}
        end
    end
  end

  @spec current_release() :: release_file() | nil
  def current_release, do: current_event_release()

  @spec current_event_release() :: release_file() | nil
  def current_event_release do
    release_state().current_event_release
  end

  @spec current_effective_release() :: release_file() | nil
  def current_effective_release do
    release_state().current_effective_release
  end

  @spec previous_rollback_target() :: release_file() | nil
  def previous_rollback_target do
    release_state().previous_rollback_target
  end

  @spec rollback_candidates() :: [release_file()]
  def rollback_candidates do
    release_state().rollback_candidates
  end

  @spec snapshot_path(String.t(), String.t()) :: String.t()
  def snapshot_path(release_id, relative_path) do
    Path.join([snapshots_dir(), release_id, relative_path])
  end

  @spec applied_path(String.t(), String.t()) :: String.t()
  def applied_path(release_id, relative_path) do
    Path.join([applied_dir(), release_id, relative_path])
  end

  defp release_path(release_id), do: Path.join(releases_dir(), "#{release_id}.json")
  defp release_path_from_name(filename), do: Path.join(releases_dir(), filename)

  defp resolve_previous_rollback_target(%{current_effective_release: nil}),
    do: {:error, "No rollback target available"}

  defp resolve_previous_rollback_target(
         %{current_effective_release: current_effective_release} = state
       ) do
    {:ok,
     %{
       restore_source: {:snapshot, current_effective_release},
       target_release_id: release_id(state.previous_rollback_target)
     }}
  end

  defp load_release_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, release} <- Jason.decode(body) do
      release
    else
      _ -> nil
    end
  end

  defp resolve_effective_release(nil, _releases_by_id), do: nil

  defp resolve_effective_release(release, releases_by_id) do
    case {Map.get(release, "status"), rollback_target_id(Map.get(release, "reason"))} do
      {"rolled_back", nil} ->
        nil

      {"rolled_back", target_release_id} ->
        releases_by_id
        |> Map.get(target_release_id)
        |> resolve_effective_release(releases_by_id)

      _ ->
        release
    end
  end

  defp effective_lineage(nil, _releases_by_id), do: []

  defp effective_lineage(release, releases_by_id) do
    Stream.unfold(release, fn
      nil -> nil
      current -> {current, Map.get(releases_by_id, Map.get(current, "parent_release_id"))}
    end)
    |> Enum.to_list()
  end

  defp rollback_target_id("rollback:" <> rest) do
    case String.trim(rest) do
      "" -> nil
      "__baseline__" -> nil
      release_id -> release_id
    end
  end

  defp rollback_target_id(_reason), do: nil

  defp release_id(nil), do: nil
  defp release_id(%{"id" => id}), do: id
end
