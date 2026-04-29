defmodule Nex.Agent.Capability.Tool.Core.SpawnTask do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  def name, do: "spawn_task"

  def description do
    "Spawn a task-scoped background subagent child run. It runs independently, returns an async task id, and reports completion through the subagent result path."
  end

  def category, do: :evolution

  def definition do
    definition([])
  end

  def definition(opts) do
    profiles = Keyword.get(opts, :subagent_profiles, %{})
    profile_names = profile_names(profiles)

    profile_description =
      if profile_names == [] do
        "Subagent profile to use. Defaults to general."
      else
        profile_lines =
          profiles
          |> Map.values()
          |> Enum.sort_by(& &1.name)
          |> Enum.map_join("; ", fn profile -> "#{profile.name}: #{profile.description}" end)

        "Subagent profile to use. Available profiles: #{profile_lines}"
      end

    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          task: %{type: "string", description: "Description of the task to perform"},
          label: %{
            type: "string",
            description: "Short label visible to the subagent and completion result."
          },
          profile: profile_schema(profile_names, profile_description),
          context: %{
            type: "string",
            description:
              "Optional concise context to provide to the subagent. Prefer only task-relevant facts."
          }
        },
        required: ["task"]
      }
    }
  end

  def execute(%{"task" => task_desc} = args, ctx) do
    label = args["label"]

    spawn_opts = [
      label: label,
      profile: args["profile"],
      context: args["context"],
      owner_run_id: Map.get(ctx, :owner_run_id) || Map.get(ctx, :run_id),
      session_key: Map.get(ctx, :session_key),
      cancel_ref: Map.get(ctx, :cancel_ref),
      provider: Map.get(ctx, :provider),
      model: Map.get(ctx, :model),
      api_key: Map.get(ctx, :api_key),
      base_url: Map.get(ctx, :base_url),
      provider_options: Map.get(ctx, :provider_options, []),
      workspace: Map.get(ctx, :workspace),
      cwd: Map.get(ctx, :cwd),
      project: Map.get(ctx, :project),
      metadata: Map.get(ctx, :metadata, %{}),
      config: Map.get(ctx, :config),
      runtime_snapshot: Map.get(ctx, :runtime_snapshot),
      channel: Map.get(ctx, :channel),
      chat_id: Map.get(ctx, :chat_id)
    ]

    if Process.whereis(Nex.Agent.Capability.Subagent) do
      {:ok, task_id} = Nex.Agent.Capability.Subagent.spawn_task(task_desc, spawn_opts)

      {:ok,
       "Background subagent task started: #{task_id} (label: #{label || "unlabeled"}, child session: subagent:#{task_id}). This is a task-scoped child run; use the returned id, completion result, child session, or ControlPlane observations to verify it. `run.owner.current` only lists active owner runs."}
    else
      {:error, "Subagent service is not running"}
    end
  end

  def execute(_args, _ctx), do: {:error, "task description is required"}

  defp profile_names(profiles) when is_map(profiles) do
    profiles
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp profile_names(_), do: []

  defp profile_schema([], description) do
    %{type: "string", description: description}
  end

  defp profile_schema(names, description) do
    %{type: "string", enum: names, description: description}
  end
end
