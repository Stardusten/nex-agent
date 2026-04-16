defmodule Nex.Agent.Outbound do
  @moduledoc false

  @spec topic_for_channel(String.t() | nil) :: atom()
  def topic_for_channel(channel) do
    case channel do
      "telegram" -> :telegram_outbound
      "feishu" -> :feishu_outbound
      "discord" -> :discord_outbound
      "slack" -> :slack_outbound
      "dingtalk" -> :dingtalk_outbound
      "http" -> :http_outbound
      _ -> :outbound
    end
  end
end
