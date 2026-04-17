defmodule Nex.Agent.Outbound do
  @moduledoc false

  @spec topic_for_channel(String.t() | nil) :: atom()
  def topic_for_channel(channel) do
    case channel do
      "feishu" -> :feishu_outbound
      "discord" -> :discord_outbound
      _ -> :outbound
    end
  end
end
