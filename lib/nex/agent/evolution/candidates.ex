defmodule Nex.Agent.Evolution.Candidates do
  @moduledoc false

  alias Nex.Agent.ControlPlane.Query

  @candidate_tags ~w(
    evolution.candidate.proposed
    evolution.candidate.approved
    evolution.candidate.rejected
    evolution.candidate.realization.generated
    evolution.candidate.realization.failed
    evolution.candidate.apply.started
    evolution.candidate.apply.completed
    evolution.candidate.apply.failed
    evolution.candidate.superseded
  )

  @status_by_tag %{
    "evolution.candidate.proposed" => "pending",
    "evolution.candidate.approved" => "approved",
    "evolution.candidate.rejected" => "rejected",
    "evolution.candidate.realization.generated" => "realized",
    "evolution.candidate.realization.failed" => "failed",
    "evolution.candidate.apply.started" => "approved",
    "evolution.candidate.apply.completed" => "applied",
    "evolution.candidate.apply.failed" => "failed",
    "evolution.candidate.superseded" => "superseded"
  }

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    opts
    |> candidate_observations()
    |> reduce_candidates()
    |> Enum.sort_by(&Map.get(&1, "proposed_at", ""), {:desc, DateTime})
  end

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def get(candidate_id, opts \\ []) when is_binary(candidate_id) do
    case Enum.find(list(opts), &(Map.get(&1, "candidate_id") == candidate_id)) do
      nil -> {:error, "Candidate not found: #{candidate_id}"}
      candidate -> {:ok, candidate}
    end
  end

  @spec reduce_candidates([map()]) :: [map()]
  def reduce_candidates(observations) when is_list(observations) do
    observations
    |> Enum.map(&normalize_observation/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.candidate_id)
    |> Enum.map(fn {candidate_id, lifecycle} ->
      lifecycle =
        lifecycle
        |> Enum.sort_by(&{&1.timestamp || "", &1.observation_id || ""})

      build_candidate(candidate_id, lifecycle)
    end)
  end

  def reduce_candidates(_), do: []

  @spec lifecycle_tags() :: [String.t()]
  def lifecycle_tags, do: @candidate_tags

  defp candidate_observations(opts) do
    Query.query(
      %{"tag_prefix" => "evolution.candidate.", "limit" => Keyword.get(opts, :limit, 200)},
      opts
    )
  end

  defp build_candidate(candidate_id, lifecycle) do
    proposed = Enum.find(lifecycle, &(&1.tag == "evolution.candidate.proposed"))
    latest = List.last(lifecycle)

    %{
      "candidate_id" => candidate_id,
      "kind" => value_from(proposed, "kind"),
      "summary" => value_from(proposed, "summary"),
      "rationale" => value_from(proposed, "rationale"),
      "evidence_ids" => value_from(proposed, "evidence_ids", []),
      "risk" => value_from(proposed, "risk", "low"),
      "status" => latest_status(lifecycle),
      "trigger" => value_from(proposed, "trigger"),
      "profile" => value_from(proposed, "profile"),
      "budget_mode" => value_from(proposed, "budget_mode"),
      "created_at" => value_from(proposed, "created_at") || (proposed && proposed.timestamp),
      "proposed_at" => proposed && proposed.timestamp,
      "decided_at" => decided_at(lifecycle),
      "applied_at" => applied_at(lifecycle),
      "latest_error" => latest_error(lifecycle),
      "lifecycle_observation_ids" => Enum.map(lifecycle, & &1.observation_id),
      "lifecycle" => Enum.map(lifecycle, &lifecycle_entry/1),
      "latest_lifecycle_tag" => latest && latest.tag
    }
  end

  defp lifecycle_entry(entry) do
    %{
      "observation_id" => entry.observation_id,
      "tag" => entry.tag,
      "timestamp" => entry.timestamp,
      "level" => entry.level,
      "attrs" => entry.attrs
    }
  end

  defp latest_status(lifecycle) do
    lifecycle
    |> Enum.reverse()
    |> Enum.find_value("pending", fn entry -> Map.get(@status_by_tag, entry.tag) end)
  end

  defp decided_at(lifecycle) do
    lifecycle
    |> Enum.find(fn entry ->
      entry.tag in ["evolution.candidate.approved", "evolution.candidate.rejected"]
    end)
    |> case do
      nil -> nil
      entry -> entry.timestamp
    end
  end

  defp applied_at(lifecycle) do
    lifecycle
    |> Enum.reverse()
    |> Enum.find(fn entry -> entry.tag == "evolution.candidate.apply.completed" end)
    |> case do
      nil -> nil
      entry -> entry.timestamp
    end
  end

  defp latest_error(lifecycle) do
    lifecycle
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      if entry.tag in [
           "evolution.candidate.realization.failed",
           "evolution.candidate.apply.failed"
         ] do
        entry.attrs["error_summary"] || entry.attrs["reason"] || entry.attrs["summary"]
      end
    end)
  end

  defp normalize_observation(observation) do
    summary = Query.observation_summary(observation)
    attrs = Map.get(summary, "attrs_summary", %{})
    candidate_id = attrs["candidate_id"] || attrs["id"]

    if summary["tag"] in @candidate_tags and is_binary(candidate_id) and candidate_id != "" do
      %{
        candidate_id: candidate_id,
        observation_id: summary["id"],
        tag: summary["tag"],
        timestamp: summary["timestamp"],
        level: summary["level"],
        attrs: attrs
      }
    end
  end

  defp value_from(entry, key, default \\ nil)
  defp value_from(nil, _key, default), do: default
  defp value_from(entry, key, default), do: Map.get(entry.attrs, key, default)
end
