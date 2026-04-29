defmodule Nex.Agent.LLM.Providers.Anthropic do
  @moduledoc false

  @behaviour Nex.Agent.Turn.LLM.ProviderAdapter

  alias Nex.Agent.Turn.LLM.ProviderProfile

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

  @impl true
  def prepare_messages_and_options(messages, _profile, options) do
    {messages, promote_model_request_options(options)}
  end

  @impl true
  def provider_options(_profile, options), do: Keyword.get(options, :provider_options, [])

  defp promote_model_request_options(options) do
    options
    |> promote_provider_option(:temperature)
    |> promote_provider_option(:max_tokens)
    |> promote_provider_option(:reasoning_effort)
  end

  defp promote_provider_option(options, key) do
    provider_options = Keyword.get(options, :provider_options, [])

    case {Keyword.get(options, key), Keyword.get(provider_options, key)} do
      {nil, value} when not is_nil(value) -> Keyword.put(options, key, value)
      _ -> options
    end
  end
end
