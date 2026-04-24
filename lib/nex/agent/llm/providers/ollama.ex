defmodule Nex.Agent.LLM.Providers.Ollama do
  @moduledoc false

  @behaviour Nex.Agent.LLM.ProviderAdapter

  alias Nex.Agent.LLM.ProviderProfile

  @base_url "http://localhost:11434/v1"
  @placeholder_api_key "ollama"

  @impl true
  def build_profile(options) do
    %ProviderProfile{
      provider: :ollama,
      resolved_provider: :openai,
      base_url: normalize_base_url(Keyword.get(options, :base_url)),
      auth_mode: nil,
      adapter: __MODULE__
    }
  end

  @impl true
  def default_model, do: "llama3.1"

  @impl true
  def default_base_url, do: @base_url

  @impl true
  def api_key_config(_profile, _options), do: {@placeholder_api_key, true}

  defp normalize_base_url(nil), do: @base_url

  defp normalize_base_url(base_url) when is_binary(base_url) do
    base_url = String.trim_trailing(base_url, "/")
    if String.ends_with?(base_url, "/v1"), do: base_url, else: base_url <> "/v1"
  end
end
