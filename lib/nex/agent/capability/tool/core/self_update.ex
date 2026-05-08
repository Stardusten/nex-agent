defmodule Nex.Agent.Capability.Tool.Core.SelfUpdate do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Self.Update.{Committer, Deployer}

  def name, do: "self_update"

  def description,
    do:
      "Preflight, deploy, inspect release visibility, and roll back CODE-layer self updates. `status` is the preflight entrypoint; `deploy` runs the quick syntax/compile/reload/related-tests path."

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["status", "deploy", "rollback", "history"],
            description: "Self-update action"
          },
          reason: %{type: "string", description: "Reason for deploy"},
          files: %{
            type: "array",
            items: %{type: "string"},
            description: "Explicit CODE-layer files to deploy"
          },
          candidate_id: %{
            type: "string",
            description: "Optional evolution candidate id associated with this deploy"
          },
          evidence_ids: %{
            type: "array",
            items: %{type: "string"},
            description:
              "Optional ControlPlane evidence observation ids associated with this deploy"
          },
          target: %{type: "string", description: "Rollback target release id or 'previous'"}
        },
        required: ["action"]
      }
    }
  end

  def execute(%{"action" => "status"} = args, _ctx) do
    {:ok, Deployer.status(Map.get(args, "files"))}
  end

  def execute(%{"action" => "history"}, _ctx) do
    {:ok, Deployer.history()}
  end

  def execute(%{"action" => "deploy", "reason" => reason} = args, ctx) do
    result =
      Deployer.deploy(
        reason,
        Map.get(args, "files"),
        deploy_opts(args, ctx)
      )

    {:ok, maybe_attach_commit_proposal(result, args, ctx)}
  end

  def execute(%{"action" => "rollback"} = args, _ctx) do
    {:ok, Deployer.rollback(Map.get(args, "target"))}
  end

  def execute(%{"action" => "deploy"}, _ctx), do: {:error, "deploy requires reason"}

  def execute(%{"action" => action}, _ctx),
    do: {:error, "Unsupported self_update action: #{action}"}

  def execute(_args, _ctx), do: {:error, "action is required"}

  defp workspace_from_ctx(ctx) when is_map(ctx) do
    Map.get(ctx, :workspace) || Map.get(ctx, "workspace")
  end

  defp workspace_from_ctx(_ctx), do: nil

  defp deploy_opts(args, ctx) do
    [
      workspace: workspace_from_ctx(ctx),
      candidate_id: Map.get(args, "candidate_id") || Map.get(args, :candidate_id),
      evidence_ids: Map.get(args, "evidence_ids") || Map.get(args, :evidence_ids)
    ]
  end

  defp maybe_attach_commit_proposal(%{status: :deployed} = result, args, ctx) do
    case Committer.prepare_from_deploy_result(result, args, ctx) do
      {:ok, proposal} ->
        Map.put(result, :source_repo_commit, proposal)

      :skip ->
        result

      {:error, reason} ->
        Map.put(result, :source_repo_commit, %{status: :unavailable, error: reason})
    end
  end

  defp maybe_attach_commit_proposal(result, _args, _ctx), do: result
end
