defmodule Nex.Agent.LLM.Providers.Default do
  @moduledoc false

  @behaviour Nex.Agent.LLM.ProviderAdapter

  alias Nex.Agent.LLM.ProviderProfile
  alias Nex.Agent.LLM.Providers.Helpers

  @impl true
  def build_profile(options) do
    provider = Keyword.get(options, :provider, :anthropic)

    %ProviderProfile{
      provider: provider,
      resolved_provider: provider,
      base_url: Keyword.get(options, :base_url),
      auth_mode: nil,
      adapter: __MODULE__
    }
  end

  @impl true
  def default_api_key, do: nil

  @impl true
  def default_model, do: "gpt-4o"

  @impl true
  def default_base_url, do: nil

  @impl true
  def prepare_messages_and_options(messages, _profile, options), do: {messages, options}

  @impl true
  def api_key_config(_profile, options) do
    api_key = Keyword.get(options, :api_key)
    {api_key, Helpers.present?(api_key)}
  end

  @impl true
  def provider_options(_profile, _options), do: []

  @impl true
  def model_spec(profile, model), do: Helpers.default_model_spec(profile, model)

  @impl true
  def stream_text_fun(%ProviderProfile{resolved_provider: :openai, base_url: base_url}) do
    if deepseek_base_url?(base_url) do
      &Nex.Agent.LLM.Providers.DeepSeekChatStream.stream_text/3
    else
      &ReqLLM.stream_text/3
    end
  end

  def stream_text_fun(_profile), do: &ReqLLM.stream_text/3

  defp deepseek_base_url?(base_url) when is_binary(base_url) do
    host =
      case URI.parse(base_url) do
        %URI{host: host} when is_binary(host) -> host
        _ -> base_url
      end

    host
    |> String.downcase()
    |> String.contains?("deepseek")
  end

  defp deepseek_base_url?(_base_url), do: false
end
