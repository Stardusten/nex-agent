defmodule Nex.Agent.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.{ContextWindow, Session}

  @projection_key "context_window_projection"

  test "select_history uses model context window as token budget" do
    session =
      Session.new("ctx-budget")
      |> add_pair("old user", "old assistant")
      |> add_pair(String.duplicate("middle user ", 80), String.duplicate("middle assistant ", 80))
      |> Session.add_message("user", String.duplicate("latest user ", 80))

    {history, attrs} =
      ContextWindow.select_history(
        session,
        "new prompt",
        "system",
        "chat",
        nil,
        [],
        model_runtime: %{context_window: 4_600},
        provider_options: [max_tokens: 100]
      )

    assert attrs.mode == "token_budget"
    assert attrs.context_window == 4_600
    assert length(history) < length(session.messages)
    assert List.last(history)["content"] =~ "latest user"
  end

  test "explicit history_limit keeps legacy message-count behavior" do
    session =
      Session.new("ctx-history-limit")
      |> add_pair("one", "two")
      |> add_pair("three", "four")

    {history, attrs} =
      ContextWindow.select_history(
        session,
        "new prompt",
        "system",
        "chat",
        nil,
        [],
        history_limit: 2,
        model_runtime: %{context_window: 4_600}
      )

    assert attrs == %{mode: "message_limit", history_limit: 2}
    assert Enum.map(history, & &1["content"]) == ["three", "four"]
  end

  test "native compaction injects provider items and projects old messages once compacted" do
    compaction_item = %{
      "id" => "cmp_123",
      "type" => "compaction",
      "encrypted_content" => "opaque"
    }

    session =
      Session.new("ctx-native")
      |> add_pair("old user", "old assistant")
      |> Session.add_message("user", "fresh user")

    session = %{
      session
      | metadata:
          Map.put(session.metadata, @projection_key, %{
            "kind" => "native_compaction",
            "compacted_until" => 2,
            "items" => [compaction_item]
          })
    }

    opts = [
      provider: :openai_codex,
      model: "gpt-5.5",
      model_runtime: %{
        context_window: 272_000,
        auto_compact_token_limit: 190_000,
        context_strategy: "server_side_then_recent"
      },
      provider_options: [max_tokens: 1_000]
    ]

    provider_options = ContextWindow.prepare_provider_options(opts, session)
    assert provider_options[:context_compaction_items] == [compaction_item]

    assert provider_options[:context_management] == [
             %{"type" => "compaction", "compact_threshold" => 190_000}
           ]

    {history, attrs} =
      ContextWindow.select_history(session, "new prompt", "system", "chat", nil, [], opts)

    assert attrs.native_compaction? == true
    assert Enum.map(history, & &1["content"]) == ["fresh user"]
  end

  test "store_response_compaction persists emitted compaction items for the next turn" do
    compaction_item = %{
      "id" => "cmp_456",
      "type" => "compaction",
      "encrypted_content" => "opaque"
    }

    session =
      Session.new("ctx-store")
      |> Session.add_message("user", "question")
      |> Session.add_message("assistant", "answer")

    opts = [
      provider: :openai_codex,
      model: "gpt-5.5",
      model_runtime: %{context_strategy: "server_side", auto_compact_token_limit: 1_000}
    ]

    response = %{response_metadata: %{context_compaction_items: [compaction_item]}}
    session = ContextWindow.store_response_compaction(session, response, opts)

    assert %{"items" => [^compaction_item], "kind" => "native_compaction"} =
             session.metadata[@projection_key]

    assert ContextWindow.prepare_provider_options(opts, session)[:context_compaction_items] == [
             compaction_item
           ]
  end

  defp add_pair(session, user, assistant) do
    session
    |> Session.add_message("user", user)
    |> Session.add_message("assistant", assistant)
  end
end
