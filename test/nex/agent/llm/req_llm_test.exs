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

  test "openai-codex-custom requests use api key auth and custom base url" do
    parent = self()

    stream_text_fun = fn model_spec, messages, opts ->
      send(parent, {:req_llm_call, model_spec, messages, opts})
      {:ok, %{stream: [%{type: :content, text: "ok"}], finish_reason: :stop}}
    end

    callback = fn event -> send(parent, {:stream_event, event}) end

    custom_base_url = "https://proxy.example.com/codex"

    assert :ok =
             AgentReqLLM.stream(
               [
                 %{"role" => "system", "content" => "You are the project copilot."},
                 %{"role" => "user", "content" => "hello from custom codex"}
               ],
               [
                 provider: :openai_codex_custom,
                 model: "gpt-5.4",
                 api_key: "custom-api-key",
                 base_url: custom_base_url,
                 req_llm_stream_text_fun: stream_text_fun
               ],
               callback
             )

    assert_receive {:req_llm_call, model_spec, messages, opts}

    assert model_spec == %{
             id: "gpt-5.4",
             provider: :openai,
             base_url: custom_base_url
           }

    assert [%Message{role: :user}] = messages
    assert opts[:api_key] == "custom-api-key"
    assert opts[:base_url] == custom_base_url
    assert opts[:provider_options][:auth_mode] == :api_key
    refute Keyword.has_key?(opts[:provider_options], :instructions)
    refute Keyword.has_key?(opts[:provider_options], :access_token)

    assert_receive {:stream_event, {:delta, "ok"}}
    assert_receive {:stream_event, {:done, metadata}}
    assert metadata[:finish_reason] == "stop"
  end

  test "file-backed image content is converted to data url before req_llm call" do
    parent = self()
    image_path = Path.join(System.tmp_dir!(), "req-llm-image-#{System.unique_integer([:positive])}.png")
    File.write!(image_path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

    on_exit(fn -> File.rm(image_path) end)

    stream_text_fun = fn model_spec, messages, opts ->
      send(parent, {:req_llm_call, model_spec, messages, opts})
      {:ok, %{stream: [%{type: :content, text: "ok"}], finish_reason: :stop}}
    end

    callback = fn event -> send(parent, {:stream_event, event}) end

    assert :ok =
             AgentReqLLM.stream(
               [
                 %{
                   "role" => "user",
                   "content" => [
                     %{
                       "type" => "image",
                       "source" => %{
                         "type" => "file",
                         "path" => image_path,
                         "media_type" => "image/png"
                       }
                     },
                     %{"type" => "text", "text" => "look"}
                   ]
                 }
               ],
               [
                 provider: :anthropic,
                 model: "claude-sonnet-4-20250514",
                 api_key: "test-key",
                 req_llm_stream_text_fun: stream_text_fun
               ],
               callback
             )

    assert_receive {:req_llm_call, _model_spec, [%Message{content: content_parts}], _opts}

    assert Enum.any?(content_parts, fn part ->
             inspect(part) =~ "data:image/png;base64,"
           end)
  end

  test "streamed tool call arguments are reconstructed before emitting tool calls" do
    callback = fn event -> send(self(), {:stream_event, event}) end

    stream_text_fun = fn _model_spec, _messages, _opts ->
      {:ok,
       %{
         stream: [
           %{type: :tool_call, name: "bash", arguments: %{}, id: "call_bash_1"},
           %ReqLLM.StreamChunk{
             type: :meta,
             metadata: %{tool_call_args: %{index: 0, fragment: ~s({"command":"ps aux"})}}
           }
         ],
         finish_reason: :tool_calls
       }}
    end

    assert :ok =
             AgentReqLLM.stream(
               [%{"role" => "user", "content" => "run ps aux"}],
               [
                 provider: :openai_codex,
                 model: "gpt-5.4",
                 api_key: "test-key",
                 base_url: "https://api.aicodemirror.com/api/codex/backend-api/codex",
                 req_llm_stream_text_fun: stream_text_fun
               ],
               callback
             )

    assert_receive {:stream_event, {:tool_calls, [tool_call]}}
    assert tool_call["function"]["name"] == "bash"
    assert Jason.decode!(tool_call["function"]["arguments"]) == %{"command" => "ps aux"}

    assert_receive {:stream_event, {:done, metadata}}
    assert metadata[:finish_reason] == "tool_calls"
  end
end
