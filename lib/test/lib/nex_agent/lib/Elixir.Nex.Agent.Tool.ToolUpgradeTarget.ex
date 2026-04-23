defmodule Nex.Agent.Tool.ToolUpgradeTarget do
  @behaviour Nex.Agent.Tool.Behaviour
  def name, do: "tool_upgrade_target"
  def description, do: "test tool"
  def category, do: :base
  def definition do
    %{name: "tool_upgrade_target", description: "test", parameters: %{type: "object", properties: %{}}}
  end
  def execute(_args, _ctx), do: {:ok, "after"}
end
