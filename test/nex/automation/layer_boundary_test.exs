defmodule Nex.Automation.LayerBoundaryTest do
  use ExUnit.Case, async: true

  test "automation entrypoint lives outside the agent runtime namespace" do
    assert Code.ensure_loaded?(Nex.Automation.Orchestrator)
    assert Code.ensure_loaded?(Nex.Agent.Orchestrator)
  end

  test "github automation implementation no longer lives under Nex.Agent.Orchestrator.*" do
    refute Code.ensure_loaded?(Nex.Agent.Orchestrator.Workflow)
    refute Code.ensure_loaded?(Nex.Agent.Orchestrator.Server)
    refute Code.ensure_loaded?(Nex.Agent.Orchestrator.WorkerRunner)
    refute Code.ensure_loaded?(Nex.Agent.Orchestrator.WorkspaceManager)
    refute Code.ensure_loaded?(Nex.Agent.Orchestrator.GitHubTracker)
  end
end
