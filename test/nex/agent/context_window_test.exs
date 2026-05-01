defmodule Nex.Agent.Turn.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.{Turn.ContextWindow, Conversation.Session}

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

  test "record_response stores provider usage anchor when usage is complete" do
    session =
      Session.new("ctx-usage")
      |> Session.add_message("user", "question")

    response = %{
      finish_reason: "stop",
      response_metadata: %{response_id: "resp_123"},
      usage: %{
        input_tokens: 10,
        cached_input_tokens: 2,
        output_tokens: 5,
        reasoning_output_tokens: 1,
        total_tokens: 15
      }
    }

    {session, attrs} =
      ContextWindow.record_response(session, response,
        provider: :openai_codex,
        model: "gpt-5.5",
        model_runtime: %{model_key: "gpt-5.5-xhigh-fast"}
      )

    assert attrs["usage_available"] == true
    assert attrs["usage_source"] == "provider"

    assert %{
             "provider" => "openai_codex",
             "model" => "gpt-5.5",
             "model_key" => "gpt-5.5-xhigh-fast",
             "last_successful_anchor" => %{
               "response_id" => "resp_123",
               "usage" => %{"source" => "provider", "total_tokens" => 15}
             }
           } = session.metadata["context_window_v2"]
  end

  test "record_response degrades to mixed usage without writing fake provider anchor" do
    session =
      Session.new("ctx-mixed")
      |> Session.add_message("user", "question")

    response = %{
      finish_reason: "stop",
      usage: %{input_tokens: 10, output_tokens: 5}
    }

    {session, attrs} =
      ContextWindow.record_response(session, response,
        provider: :openai_compatible,
        model: "remote-model"
      )

    assert attrs["usage_available"] == true
    assert attrs["usage_source"] == "mixed"
    refute Map.has_key?(session.metadata["context_window_v2"], "last_successful_anchor")
  end

  test "record_response stores incomplete evidence without usage" do
    session =
      Session.new("ctx-incomplete")
      |> Session.add_message("user", "question")

    response = %{
      finish_reason: "incomplete",
      response_metadata: %{incomplete_reason: "max_output_tokens"}
    }

    {session, attrs} =
      ContextWindow.record_response(session, response,
        provider: :openai_codex,
        model: "gpt-5.5"
      )

    assert attrs["usage_available"] == false
    assert attrs["usage_source"] == "estimate"

    assert %{"last_incomplete" => %{"reason" => "max_output_tokens", "usage" => %{}}} =
             session.metadata["context_window_v2"]
  end

  test "truncate_tool_result derives limit from small model context budget" do
    result = String.duplicate("a", 10_000)

    {visible, attrs} =
      ContextWindow.truncate_tool_result(result,
        model_runtime: %{context_window: 5_000},
        provider_options: [max_tokens: 100]
      )

    assert attrs["truncated?"] == true
    assert attrs["token_limit"] == 512
    assert attrs["token_limit_source"] == "context_budget"
    assert attrs["visible_tokens_estimate"] <= attrs["token_limit"] + 5
    assert visible =~ "truncated to"
  end

  test "truncate_tool_result allows larger output for large model context budget" do
    result = String.duplicate("a", 10_000)

    {_visible, attrs} =
      ContextWindow.truncate_tool_result(result,
        model_runtime: %{context_window: 250_000},
        provider_options: [max_tokens: 4_096]
      )

    assert attrs["truncated?"] == false
    assert attrs["token_limit"] == 16_000
  end

  test "truncate_tool_result honors explicit tool output token limit" do
    result = String.duplicate("a", 1_000)

    {visible, attrs} =
      ContextWindow.truncate_tool_result(result,
        model_runtime: %{context_window: 250_000, tool_output_token_limit: 50}
      )

    assert attrs["truncated?"] == true
    assert attrs["token_limit"] == 50
    assert attrs["token_limit_source"] == "config"
    assert visible =~ "truncated to 50 estimated tokens"
  end

  defp add_pair(session, user, assistant) do
    session
    |> Session.add_message("user", user)
    |> Session.add_message("assistant", assistant)
  end
end
