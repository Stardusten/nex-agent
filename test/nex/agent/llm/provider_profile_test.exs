defmodule Nex.Agent.LLM.ProviderProfileTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.LLM.ProviderProfile
  alias Nex.Agent.LLM.Providers

  test "openai_codex default profile uses ChatGPT Codex OAuth backend" do
    profile = ProviderProfile.for(:openai_codex, [])

    assert profile.provider == :openai_codex
    assert profile.resolved_provider == :openai
    assert profile.base_url == "https://chatgpt.com/backend-api/codex"
    assert profile.auth_mode == :oauth
    assert profile.adapter == Providers.OpenAICodex
  end

  test "openai_codex custom base URL uses api key mode and system_prompt path" do
    profile =
      ProviderProfile.for(:openai_codex,
        base_url: "https://proxy.example.com/codex/",
        provider_options: [instructions: "stale"]
      )

    {messages, options} =
      ProviderProfile.prepare_messages_and_options(
        [
          %{"role" => "system", "content" => "Use the workspace rules."},
          %{"role" => "user", "content" => "hello"}
        ],
        profile,
        provider_options: [instructions: "stale"]
      )

    provider_options = ProviderProfile.provider_options(profile, options)

    assert profile.auth_mode == :api_key
    assert profile.base_url == "https://proxy.example.com/codex"
    assert [%{"role" => "user"}] = messages
    assert options[:system_prompt] == "Use the workspace rules."
    refute Keyword.has_key?(provider_options, :instructions)
    assert provider_options[:auth_mode] == :api_key
  end

  test "openai_codex_custom always uses api key mode" do
    profile =
      ProviderProfile.for(:openai_codex_custom,
        base_url: "https://custom.example.com/backend-api/codex/"
      )

    {messages, options} =
      ProviderProfile.prepare_messages_and_options(
        [
          %{"role" => "system", "content" => "Custom instructions"},
          %{"role" => "user", "content" => "hello"}
        ],
        profile,
        provider_options: [instructions: "remove-me", access_token: "remove-me"]
      )

    provider_options = ProviderProfile.provider_options(profile, options)

    assert profile.provider == :openai_codex_custom
    assert profile.resolved_provider == :openai
    assert profile.auth_mode == :api_key
    assert profile.base_url == "https://custom.example.com/backend-api/codex"
    assert [%{"role" => "user"}] = messages
    assert options[:system_prompt] == "Custom instructions"
    refute Keyword.has_key?(provider_options, :instructions)
    refute Keyword.has_key?(provider_options, :access_token)
    assert provider_options[:auth_mode] == :api_key
  end

  test "openrouter injects app provider options" do
    profile = ProviderProfile.for(:openrouter, [])

    assert profile.adapter == Providers.OpenRouter
    assert profile.base_url == "https://openrouter.ai/api/v1"
    assert ProviderProfile.default_model(profile) == "anthropic/claude-3.5-sonnet"

    assert ProviderProfile.provider_options(profile, []) == [
             app_referer: "https://nex.dev",
             app_title: "Nex Agent"
           ]
  end

  test "ollama normalizes base URL and uses placeholder api key" do
    profile = ProviderProfile.for(:ollama, base_url: "http://localhost:11434/")

    assert profile.adapter == Providers.Ollama
    assert profile.resolved_provider == :openai
    assert profile.base_url == "http://localhost:11434/v1"
    assert ProviderProfile.default_model(profile) == "llama3.1"
    assert ProviderProfile.api_key_config(profile, []) == {"ollama", true}
  end

  test "facade delegates model spec and stream fun to adapter" do
    codex = ProviderProfile.for(:openai_codex, [])
    custom = ProviderProfile.for(:openai_codex, base_url: "https://proxy.example.com/codex")

    assert ProviderProfile.model_spec(codex, "gpt-5.5") == %{
             id: "gpt-5.5",
             provider: :openai,
             base_url: "https://chatgpt.com/backend-api/codex"
           }

    assert function_target(ProviderProfile.stream_text_fun(codex)) ==
             {Nex.Agent.LLM.Providers.OpenAICodex.Stream, :stream_text, 3}

    assert function_target(ProviderProfile.stream_text_fun(custom)) == {ReqLLM, :stream_text, 3}
  end

  test "unknown provider uses default adapter without raising" do
    profile = ProviderProfile.for(:future_provider, base_url: "https://future.example.com/v1")

    assert profile.adapter == Providers.Default
    assert profile.provider == :future_provider

    assert ProviderProfile.model_spec(profile, "future-model") == %{
             id: "future-model",
             provider: :future_provider,
             base_url: "https://future.example.com/v1"
           }
  end

  defp function_target(fun) when is_function(fun) do
    {:module, module} = :erlang.fun_info(fun, :module)
    {:name, name} = :erlang.fun_info(fun, :name)
    {:arity, arity} = :erlang.fun_info(fun, :arity)
    {module, name, arity}
  end
end
