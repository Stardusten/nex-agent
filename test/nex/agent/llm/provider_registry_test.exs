defmodule Nex.Agent.LLM.ProviderRegistryTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.LLM.ProviderRegistry
  alias Nex.Agent.LLM.Providers

  test "known providers lists registered provider adapters" do
    assert Enum.sort(ProviderRegistry.known_providers()) ==
             Enum.sort([
               :anthropic,
               :openrouter,
               :ollama,
               :openai_codex,
               :openai_codex_custom
             ])
  end

  test "adapter_for returns registered adapters and falls back for unknown providers" do
    assert ProviderRegistry.adapter_for(:anthropic) == Providers.Anthropic
    assert ProviderRegistry.adapter_for(:openrouter) == Providers.OpenRouter
    assert ProviderRegistry.adapter_for(:ollama) == Providers.Ollama
    assert ProviderRegistry.adapter_for(:openai_codex) == Providers.OpenAICodex
    assert ProviderRegistry.adapter_for(:openai_codex_custom) == Providers.OpenAICodexCustom
    assert ProviderRegistry.adapter_for(:future_provider) == Providers.Default
  end
end
