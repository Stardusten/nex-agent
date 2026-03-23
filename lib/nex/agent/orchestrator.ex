defmodule Nex.Agent.Orchestrator do
  @moduledoc false

  @deprecated "Use Nex.Automation.Orchestrator instead."

  alias Nex.Automation.Orchestrator
  alias Nex.Automation.Workflow

  @spec start(String.t(), keyword()) :: {:ok, pid()} | {:error, String.t()}
  defdelegate start(workflow_path, opts \\ []), to: Orchestrator

  @spec status(String.t()) :: {:ok, map()} | {:error, String.t()}
  defdelegate status(workflow_path), to: Orchestrator

  @spec status_path(Workflow.t()) :: String.t()
  defdelegate status_path(workflow), to: Orchestrator
end
