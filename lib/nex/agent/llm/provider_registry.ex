defmodule Nex.Agent.LLM.ProviderRegistry do
  @moduledoc false

  alias Nex.Agent.LLM.Providers

  @adapters %{
    anthropic: Providers.Anthropic,
    openrouter: Providers.OpenRouter,
    ollama: Providers.Ollama,
    openai_codex: Providers.OpenAICodex,
    openai_codex_custom: Providers.OpenAICodexCustom
  }

  @spec adapter_for(atom()) :: module()
  def adapter_for(provider) when is_atom(provider) do
    Map.get(@adapters, provider, Providers.Default)
  end

  def adapter_for(_provider), do: Providers.Default

  @spec known_providers() :: [atom()]
  def known_providers do
    Map.keys(@adapters)
  end
end
