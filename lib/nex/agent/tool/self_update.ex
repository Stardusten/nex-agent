defmodule Nex.Agent.Tool.SelfUpdate do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.SelfUpdate.Deployer

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

  def execute(%{"action" => "deploy", "reason" => reason} = args, _ctx) do
    {:ok, Deployer.deploy(reason, Map.get(args, "files"))}
  end

  def execute(%{"action" => "rollback"} = args, _ctx) do
    {:ok, Deployer.rollback(Map.get(args, "target"))}
  end

  def execute(%{"action" => "deploy"}, _ctx), do: {:error, "deploy requires reason"}

  def execute(%{"action" => action}, _ctx),
    do: {:error, "Unsupported self_update action: #{action}"}

  def execute(_args, _ctx), do: {:error, "action is required"}
end
