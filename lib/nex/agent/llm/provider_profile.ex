defmodule Nex.Agent.LLM.ProviderProfile do
  @moduledoc false

  alias Nex.Agent.LLM.ProviderRegistry

  defstruct provider: :anthropic,
            resolved_provider: :anthropic,
            base_url: nil,
            auth_mode: nil,
            adapter: nil

  @type t :: %__MODULE__{
          provider: atom(),
          resolved_provider: atom(),
          base_url: String.t() | nil,
          auth_mode: atom() | nil,
          adapter: module() | nil
        }

  @spec for(atom(), keyword()) :: t()
  def for(provider, options \\ []) do
    provider = normalize_provider(provider)
    adapter = ProviderRegistry.adapter_for(provider)

    options
    |> Keyword.put(:provider, provider)
    |> adapter.build_profile()
  end

  @spec default_api_key(atom()) :: String.t() | nil
  def default_api_key(provider) do
    provider
    |> normalize_provider()
    |> ProviderRegistry.adapter_for()
    |> call_adapter(:default_api_key, [])
  end

  @spec default_model(atom() | t()) :: String.t()
  def default_model(%__MODULE__{} = profile) do
    profile
    |> adapter_for_profile()
    |> call_adapter(:default_model, [])
  end

  def default_model(provider) do
    provider
    |> normalize_provider()
    |> ProviderRegistry.adapter_for()
    |> call_adapter(:default_model, [])
  end

  @spec default_base_url(atom()) :: String.t() | nil
  def default_base_url(provider) do
    provider
    |> normalize_provider()
    |> ProviderRegistry.adapter_for()
    |> call_adapter(:default_base_url, [])
  end

  @spec prepare_messages_and_options([map()], t(), keyword()) :: {[map()], keyword()}
  def prepare_messages_and_options(messages, %__MODULE__{} = profile, options) do
    profile
    |> adapter_for_profile()
    |> call_adapter(:prepare_messages_and_options, [messages, profile, options])
  end

  @spec api_key_config(t(), keyword()) :: {String.t() | nil, boolean()}
  def api_key_config(%__MODULE__{} = profile, options) do
    profile
    |> adapter_for_profile()
    |> call_adapter(:api_key_config, [profile, options])
  end

  @spec provider_options(t(), keyword()) :: keyword()
  def provider_options(%__MODULE__{} = profile, options) do
    profile
    |> adapter_for_profile()
    |> call_adapter(:provider_options, [profile, options])
  end

  @spec stream_text_fun(t()) :: Nex.Agent.LLM.ProviderAdapter.stream_text_fun()
  def stream_text_fun(%__MODULE__{} = profile) do
    profile
    |> adapter_for_profile()
    |> call_adapter(:stream_text_fun, [profile])
  end

  @spec model_spec(t(), String.t()) :: String.t() | map()
  def model_spec(%__MODULE__{} = profile, model) when is_binary(model) do
    profile
    |> adapter_for_profile()
    |> call_adapter(:model_spec, [profile, model])
  end

  defp call_adapter(adapter, function, args) do
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, function, length(args)) do
      apply(adapter, function, args)
    else
      apply(Nex.Agent.LLM.Providers.Default, function, args)
    end
  end

  defp adapter_for_profile(%__MODULE__{adapter: adapter})
       when is_atom(adapter) and not is_nil(adapter),
       do: adapter

  defp adapter_for_profile(%__MODULE__{provider: provider}),
    do: ProviderRegistry.adapter_for(provider)

  defp normalize_provider(provider) when is_atom(provider), do: provider
  defp normalize_provider(_), do: :anthropic
end
