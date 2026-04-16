defmodule Nex.Agent.LLM.ReqLLMTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.LLM.ReqLLM, as: AgentReqLLM
  alias ReqLLM.Message

  test "ollama requests use a non-empty placeholder api key" do
    previous_openai_key = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "")

    on_exit(fn ->
      if previous_openai_key do
        System.put_env("OPENAI_API_KEY", previous_openai_key)
      else
        System.delete_env("OPENAI_API_KEY")
      end
    end)

    parent = self()

    stream_text_fun = fn model_spec, messages, opts ->
      send(parent, {:req_llm_call, model_spec, messages, opts})
      {:ok, %{stream: [%{type: :content, text: "ok"}], finish_reason: :stop}}
    end

    callback = fn event -> send(parent, {:stream_event, event}) end

    assert :ok =
             AgentReqLLM.stream(
               [%{"role" => "user", "content" => "hello from ollama"}],
               [
                 provider: :ollama,
                 model: "qwen2.5:latest",
                 base_url: "http://localhost:11434",
                 req_llm_stream_text_fun: stream_text_fun
               ],
               callback
             )

    assert_receive {:req_llm_call, model_spec, messages, opts}

    assert model_spec == %{
             id: "qwen2.5:latest",
             provider: :openai,
             base_url: "http://localhost:11434/v1"
           }

    assert [%Message{role: :user}] = messages
    assert opts[:api_key] == "ollama"
    assert opts[:base_url] == "http://localhost:11434/v1"

    assert_receive {:stream_event, {:delta, "ok"}}
    assert_receive {:stream_event, {:done, metadata}}
    assert metadata[:finish_reason] == "stop"
  end

  test "openai-codex requests use oauth access token and codex responses endpoint base url" do
    parent = self()

    stream_text_fun = fn model_spec, messages, opts ->
      send(parent, {:req_llm_call, model_spec, messages, opts})
      {:ok, %{stream: [%{type: :content, text: "ok"}], finish_reason: :stop}}
    end

    callback = fn event -> send(parent, {:stream_event, event}) end

    assert :ok =
             AgentReqLLM.stream(
               [
                 %{"role" => "system", "content" => "You are the project copilot."},
                 %{"role" => "user", "content" => "hello from codex"}
               ],
               [
                 provider: :openai_codex,
                 model: "gpt-5.3-codex",
                 api_key: "oauth-access-token",
                 req_llm_stream_text_fun: stream_text_fun
               ],
               callback
             )

    assert_receive {:req_llm_call, model_spec, messages, opts}

    assert model_spec == %{
             id: "gpt-5.3-codex",
             provider: :openai,
             base_url: "https://chatgpt.com/backend-api/codex"
           }

    assert [%Message{role: :user}] = messages
    assert opts[:api_key] == nil
    assert opts[:base_url] == "https://chatgpt.com/backend-api/codex"
    assert opts[:provider_options][:instructions] == "You are the project copilot."
    assert opts[:provider_options][:auth_mode] == :oauth
    assert opts[:provider_options][:access_token] == "oauth-access-token"

    assert_receive {:stream_event, {:delta, "ok"}}
    assert_receive {:stream_event, {:done, metadata}}
    assert metadata[:finish_reason] == "stop"
  end

  test "openai-codex requests use regular api key auth for third-party codex-compatible base urls" do
    parent = self()

    stream_text_fun = fn model_spec, messages, opts ->
      send(parent, {:req_llm_call, model_spec, messages, opts})
      {:ok, %{stream: [%{type: :content, text: "ok"}], finish_reason: :stop}}
    end

    callback = fn event -> send(parent, {:stream_event, event}) end

    third_party_base_url = "https://api.aicodemirror.com/api/codex/backend-api/codex"

    assert :ok =
             AgentReqLLM.stream(
               [
                 %{"role" => "system", "content" => "You are the project copilot."},
                 %{"role" => "user", "content" => "hello from codex"}
               ],
               [
                 provider: :openai_codex,
                 model: "gpt-5.3-codex",
                 api_key: "third-party-api-key",
                 base_url: third_party_base_url,
                 req_llm_stream_text_fun: stream_text_fun
               ],
               callback
             )

    assert_receive {:req_llm_call, model_spec, messages, opts}

    assert model_spec == %{
             id: "gpt-5.3-codex",
             provider: :openai,
             base_url: third_party_base_url
           }

    assert [%Message{role: :user}] = messages
    assert opts[:api_key] == "third-party-api-key"
    assert opts[:base_url] == third_party_base_url
    assert opts[:provider_options][:auth_mode] == :api_key
    refute Keyword.has_key?(opts[:provider_options], :instructions)
    refute Keyword.has_key?(opts[:provider_options], :access_token)

    assert_receive {:stream_event, {:delta, "ok"}}
    assert_receive {:stream_event, {:done, metadata}}
    assert metadata[:finish_reason] == "stop"
  end
end
