defmodule Nex.Agent.App.InfrastructureSupervisor do
  @moduledoc """
  Supervisor for infrastructure services: Bus, Tool.Registry, MCP, Cron, Heartbeat.

  All children are independent (:one_for_one) — one crashing does not affect others.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Nex.Agent.App.Bus,
      Nex.Agent.Capability.Tool.Registry,
      Nex.Agent.Interface.MCP.ServerManager,
      Nex.Agent.Knowledge.Memory.Updater,
      Nex.Agent.Capability.Cron,
      Nex.Agent.App.Heartbeat
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
