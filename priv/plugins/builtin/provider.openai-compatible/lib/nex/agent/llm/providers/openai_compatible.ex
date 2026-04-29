defmodule Nex.Agent.LLM.Providers.OpenAICompatible do
  @moduledoc false

  @behaviour Nex.Agent.Turn.LLM.ProviderAdapter

  alias Nex.Agent.Turn.LLM.ProviderProfile
  alias Nex.Agent.LLM.Providers.DeepSeekChatStream
  alias Nex.Agent.Turn.LLM.Providers.Helpers

  @impl true
  def build_profile(options) do
    %ProviderProfile{
      provider: :openai_compatible,
      resolved_provider: :openai,
      base_url: Helpers.trim_base_url(Keyword.get(options, :base_url)),
      auth_mode: nil,
      adapter: __MODULE__
    }
  end

  @impl true
  def default_api_key, do: System.get_env("OPENAI_API_KEY")

  @impl true
  def default_model, do: "gpt-4o"

  @impl true
  def prepare_messages_and_options(messages, _profile, options) do
    {messages, promote_model_request_options(options)}
  end

  @impl true
  def api_key_config(_profile, options) do
    api_key = Keyword.get(options, :api_key) || default_api_key()
    {api_key, Helpers.present?(api_key)}
  end

  @impl true
  def provider_options(_profile, options) do
    options
    |> Keyword.get(:provider_options, [])
    |> normalize_provider_options()
  end

  @impl true
  def stream_text_fun(%ProviderProfile{base_url: base_url}) do
    if Helpers.deepseek_base_url?(base_url),
      do: &DeepSeekChatStream.stream_text/3,
      else: &ReqLLM.stream_text/3
  end

  @impl true
  def forced_tool_choice(%ProviderProfile{base_url: base_url}, name) do
    if Helpers.deepseek_base_url?(base_url), do: nil, else: %{type: "tool", name: name}
  end

  defp promote_model_request_options(options) do
    options
    |> promote_provider_option(:temperature, & &1)
    |> promote_provider_option(:max_tokens, & &1)
    |> promote_provider_option(:reasoning_effort, &normalize_reasoning_effort/1)
    |> promote_provider_option(:service_tier, & &1)
  end

  defp promote_provider_option(options, key, normalize) do
    provider_options = Keyword.get(options, :provider_options, [])

    case {Keyword.get(options, key), Keyword.get(provider_options, key)} do
      {nil, value} when not is_nil(value) -> Keyword.put(options, key, normalize.(value))
      _ -> options
    end
  end

  defp normalize_provider_options(provider_options) when is_list(provider_options) do
    if Keyword.has_key?(provider_options, :reasoning_effort) do
      Keyword.update!(provider_options, :reasoning_effort, &normalize_reasoning_effort/1)
    else
      provider_options
    end
  end

  defp normalize_provider_options(_provider_options), do: []

  defp normalize_reasoning_effort(value) when value in ["extra high", "extra_high"],
    do: "xhigh"

  defp normalize_reasoning_effort(value), do: value
end
