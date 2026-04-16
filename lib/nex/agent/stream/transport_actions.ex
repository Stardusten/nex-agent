defmodule Nex.Agent.Stream.TransportActions do
  @moduledoc false

  alias Nex.Agent.{Bus, Outbound}

  @spec run([term()]) :: :ok
  def run(actions) when is_list(actions) do
    Enum.each(actions, fn
      {:publish, channel, chat_id, content, metadata} ->
        outbound_topic = Outbound.topic_for_channel(channel)
        Bus.publish(outbound_topic, %{chat_id: chat_id, content: content, metadata: metadata})

      _ ->
        :ok
    end)

    :ok
  end
end
