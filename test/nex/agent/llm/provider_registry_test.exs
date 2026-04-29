defmodule Nex.Agent.Turn.LLM.ProviderRegistryTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Turn.LLM.ProviderRegistry
  alias Nex.Agent.Turn.LLM.Providers, as: CoreProviders
  alias Nex.Agent.LLM.Providers
  alias Nex.Agent.Runtime.Config

  test "known providers lists registered provider adapters" do
    assert Enum.sort(ProviderRegistry.known_providers()) ==
             Enum.sort([
               :anthropic,
               :openai,
               :openai_compatible,
               :openrouter,
               :ollama,
               :openai_codex,
               :openai_codex_custom
             ])
  end

  test "adapter_for returns registered adapters and falls back for unknown providers" do
    assert ProviderRegistry.adapter_for(:anthropic) == Providers.Anthropic
    assert ProviderRegistry.adapter_for(:openai) == Providers.OpenAI
    assert ProviderRegistry.adapter_for(:openai_compatible) == Providers.OpenAICompatible
    assert ProviderRegistry.adapter_for(:openrouter) == Providers.OpenRouter
    assert ProviderRegistry.adapter_for(:ollama) == Providers.Ollama
    assert ProviderRegistry.adapter_for(:openai_codex) == Providers.OpenAICodex
    assert ProviderRegistry.adapter_for(:openai_codex_custom) == Providers.OpenAICodexCustom
    assert ProviderRegistry.adapter_for(:future_provider) == CoreProviders.Default
  end

  test "disabled provider plugin removes provider from registry projection" do
    config = Config.from_map(%{"plugins" => %{"disabled" => ["builtin:provider.openrouter"]}})

    refute :openrouter in ProviderRegistry.known_providers(config: config)
    refute "openrouter" in ProviderRegistry.known_provider_types(config: config)
    assert ProviderRegistry.adapter_for(:openrouter, config: config) == CoreProviders.Default
  end
end
