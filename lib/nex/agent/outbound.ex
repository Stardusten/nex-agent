defmodule Nex.Agent.Outbound do
  @moduledoc false

  @spec topic_for_channel(String.t() | nil) :: {:channel_outbound, String.t()} | :outbound
  def topic_for_channel(channel) do
    case to_string(channel || "") do
      "" -> :outbound
      instance_id -> {:channel_outbound, instance_id}
    end
  end
end
