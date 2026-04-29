defmodule Nex.Agent.LLM.Providers.OpenRouter do
  @moduledoc false

  @behaviour Nex.Agent.Turn.LLM.ProviderAdapter

  alias Nex.Agent.Turn.LLM.ProviderProfile

  @base_url "https://openrouter.ai/api/v1"
  @app_referer "https://nex.dev"
  @app_title "Nex Agent"

  @impl true
  def build_profile(options) do
    %ProviderProfile{
      provider: :openrouter,
      resolved_provider: :openrouter,
      base_url: Keyword.get(options, :base_url) || @base_url,
      auth_mode: nil,
      adapter: __MODULE__
    }
  end

  @impl true
  def default_model, do: "anthropic/claude-3.5-sonnet"

  @impl true
  def default_base_url, do: @base_url

  @impl true
  def provider_options(_profile, options) do
    options
    |> Keyword.get(:provider_options, [])
    |> put_default_option(:app_referer, @app_referer)
    |> put_default_option(:app_title, @app_title)
  end

  defp put_default_option(options, key, value) do
    if Keyword.has_key?(options, key), do: options, else: options ++ [{key, value}]
  end
end
