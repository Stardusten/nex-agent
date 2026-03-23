defmodule Nex.Automation.Orchestrator do
  @moduledoc false

  alias Nex.Automation.{Server, Workflow}

  @spec start(String.t(), keyword()) :: {:ok, pid()} | {:error, String.t()}
  def start(workflow_path, opts \\ []) do
    with {:ok, workflow} <- Workflow.load(workflow_path) do
      Server.start_link([workflow: workflow] ++ opts)
    end
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, String.t()}
  def status(workflow_path) do
    with {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, body} <- File.read(status_path(workflow)),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok,
       decoded
       |> Map.put_new("workflow_path", Path.expand(workflow_path))
       |> Map.put_new("last_poll_at", nil)
       |> Map.put_new("running", [])
       |> Map.put_new("completed", [])
       |> Map.put_new("failed", [])
       |> Map.put_new("cancelled", [])}
    else
      {:error, :enoent} -> {:error, "No orchestrator status snapshot found yet"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @spec status_path(Workflow.t()) :: String.t()
  def status_path(%Workflow{repo_root: repo_root}) do
    Path.join(repo_root, ".nex/orchestrator/status.json")
  end
end
