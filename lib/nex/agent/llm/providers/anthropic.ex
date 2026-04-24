defmodule Nex.Agent.LLM.Providers.Anthropic do
  @moduledoc false

  @behaviour Nex.Agent.LLM.ProviderAdapter

  alias Nex.Agent.LLM.ProviderProfile

  @impl true
  def build_profile(options) do
    %ProviderProfile{
      provider: :anthropic,
      resolved_provider: :anthropic,
      base_url: Keyword.get(options, :base_url),
      auth_mode: nil,
      adapter: __MODULE__
    }
  end

  @impl true
  def default_model, do: "claude-sonnet-4-20250514"
end
