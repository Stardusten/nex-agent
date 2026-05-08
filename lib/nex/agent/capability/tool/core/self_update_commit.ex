defmodule Nex.Agent.Capability.Tool.Core.SelfUpdateCommit do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Self.Update.Committer

  def name, do: "self_update_commit"

  def description,
    do:
      "Inspect the configured source repo, prepare a Git commit message for a successful self_update release, and create the commit only after owner approval."

  def category, do: :evolution
  def surfaces, do: [:all, :base]

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["status", "prepare", "commit"],
            description:
              "status checks configured source repo, prepare returns the proposed commit message, commit requests owner approval and runs git commit"
          },
          release_id: %{
            type: "string",
            description: "self_update release id returned from a successful deploy"
          },
          candidate_id: %{
            type: "string",
            description: "Optional evolution candidate id associated with the release"
          },
          evidence_ids: %{
            type: "array",
            items: %{type: "string"},
            description: "Optional ControlPlane evidence observation ids"
          },
          message: %{
            type: "string",
            description:
              "Optional explicit commit message. When omitted, the tool builds one from release, candidate, and evidence."
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(%{"action" => "status"}, ctx), do: Committer.status(ctx)

  def execute(%{"action" => "prepare"} = args, ctx), do: Committer.prepare(args, ctx)

  def execute(%{"action" => "commit"} = args, ctx), do: Committer.commit(args, ctx)

  def execute(%{"action" => action}, _ctx),
    do: {:error, "Unsupported self_update_commit action: #{action}"}

  def execute(_args, _ctx), do: {:error, "action is required"}
end
