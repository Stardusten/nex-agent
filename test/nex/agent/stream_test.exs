defmodule Nex.Agent.StreamTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Stream.{Event, MultiMessageSession, Result, Transport}

  test "stream result contract exposes handled sentinel and final content" do
    result = Result.ok("run_1", "hello", %{transport: :multi_message})

    assert %Result{
             handled?: true,
             run_id: "run_1",
             status: :ok,
             final_content: "hello",
             error: nil
           } = result

    assert to_string(result) == "hello"
  end

  test "message session consumes unified events through transport facade" do
    session =
      MultiMessageSession.new(
        key: {:workspace, "telegram:chat-1"},
        channel: "telegram",
        chat_id: "chat-1",
        metadata: %{}
      )

    event = %Event{seq: 1, run_id: "run_1", type: :text_delta, content: "hello"}
    {session, actions} = Transport.handle_event(session, event)

    assert Transport.capability(session) == :multi_message
    assert actions == []

    event = %Event{seq: 2, run_id: "run_1", type: :message_end, content: "hello"}
    {_session, actions} = Transport.handle_event(session, event)

    assert actions == [{:publish, "telegram", "chat-1", "hello", %{}}]
  end
end
