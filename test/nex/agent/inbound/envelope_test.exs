defmodule Nex.Agent.Inbound.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Inbound.Envelope

  test "envelope keeps canonical inbound fields" do
    envelope = %Envelope{
      channel: "feishu",
      chat_id: "chat-1",
      sender_id: "ou_123",
      text: "hello",
      message_type: :text,
      raw: %{"event" => %{}},
      metadata: %{"message_type" => "text"},
      media_refs: [],
      attachments: []
    }

    assert envelope.channel == "feishu"
    assert envelope.chat_id == "chat-1"
    assert envelope.text == "hello"
    assert envelope.message_type == :text
  end
end
