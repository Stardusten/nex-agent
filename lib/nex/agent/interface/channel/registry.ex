defmodule Nex.Agent.Interface.Channel.Registry do
  @moduledoc false

  @registry Nex.Agent.ChannelRegistry

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts \\ []) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @spec via(String.t() | atom()) :: {:via, Registry, {module(), String.t()}}
  def via(instance_id), do: {:via, Registry, {@registry, to_string(instance_id)}}

  @spec whereis(String.t() | atom() | nil) :: pid() | nil
  def whereis(nil), do: nil

  def whereis(instance_id) do
    if Process.whereis(@registry) do
      case Registry.lookup(@registry, to_string(instance_id)) do
        [{pid, _value} | _] -> pid
        [] -> nil
      end
    end
  end
end
