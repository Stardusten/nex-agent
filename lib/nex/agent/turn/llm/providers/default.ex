defmodule Nex.Agent.Turn.LLM.Providers.Default do
  @moduledoc false

  @behaviour Nex.Agent.Turn.LLM.ProviderAdapter

  alias Nex.Agent.Turn.LLM.ProviderProfile
  alias Nex.Agent.Turn.LLM.Providers.Helpers

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
  def stream_text_fun(_profile), do: &ReqLLM.stream_text/3

  @impl true
  def forced_tool_choice(_profile, name), do: %{type: "tool", name: name}
end
