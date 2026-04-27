defmodule Nex.Agent.LLM.Providers.OpenAICodex do
  @moduledoc false

  @behaviour Nex.Agent.LLM.ProviderAdapter

  alias Nex.Agent.Auth.Codex
  alias Nex.Agent.LLM.ProviderProfile
  alias Nex.Agent.LLM.Providers.Default
  alias Nex.Agent.LLM.Providers.Helpers
  alias Nex.Agent.LLM.Providers.OpenAICodex.Stream

  @impl true
  def build_profile(options) do
    base_url = effective_base_url(Keyword.get(options, :base_url))

    %ProviderProfile{
      provider: :openai_codex,
      resolved_provider: :openai,
      base_url: base_url,
      auth_mode: auth_mode(base_url),
      adapter: __MODULE__
    }
  end

  @impl true
  def default_api_key do
    case System.get_env("OPENAI_CODEX_ACCESS_TOKEN") do
      token when is_binary(token) and token != "" ->
        token

      _ ->
        case Codex.resolve_access_token() do
          {:ok, token} -> token
          _ -> nil
        end
    end
  end

  @impl true
  def default_base_url, do: Codex.default_base_url()

  @impl true
  def default_model, do: "gpt-5.3-codex"

  @impl true
  def prepare_messages_and_options(messages, %ProviderProfile{} = profile, options) do
    {instructions, filtered_messages} = Helpers.extract_system_instructions(messages)
    options = promote_model_request_options(options)
    provider_options = Keyword.get(options, :provider_options, [])

    prepared_options =
      case profile.auth_mode do
        :oauth ->
          Keyword.put(
            options,
            :provider_options,
            Keyword.put(provider_options, :instructions, instructions)
          )

        :api_key ->
          options
          |> Keyword.put(:system_prompt, instructions)
          |> Keyword.put(:provider_options, Keyword.delete(provider_options, :instructions))

        _ ->
          options
      end

    {filtered_messages, prepared_options}
  end

  @impl true
  def api_key_config(%ProviderProfile{auth_mode: :oauth}, _options), do: {nil, false}

  def api_key_config(profile, options), do: Default.api_key_config(profile, options)

  @impl true
  def provider_options(%ProviderProfile{auth_mode: :oauth}, options) do
    base = Keyword.get(options, :provider_options, [])
    access_token = Keyword.get(options, :api_key)
    instructions = Keyword.get(base, :instructions, "You are a helpful coding assistant.")

    base
    |> Keyword.put(:instructions, instructions)
    |> Keyword.put(:auth_mode, :oauth)
    |> maybe_put_keyword(:access_token, Helpers.present?(access_token), access_token)
  end

  def provider_options(%ProviderProfile{auth_mode: :api_key}, options) do
    options
    |> Keyword.get(:provider_options, [])
    |> Keyword.delete(:instructions)
    |> Keyword.put(:auth_mode, :api_key)
    |> Keyword.delete(:access_token)
  end

  @impl true
  def stream_text_fun(%ProviderProfile{auth_mode: :oauth}), do: &Stream.stream_text/3
  def stream_text_fun(profile), do: Default.stream_text_fun(profile)

  defp effective_base_url(nil), do: Codex.default_base_url()
  defp effective_base_url(base_url) when is_binary(base_url), do: Helpers.trim_base_url(base_url)

  defp auth_mode(base_url) when is_binary(base_url) do
    if base_url == Codex.default_base_url(), do: :oauth, else: :api_key
  end

  defp auth_mode(_base_url), do: nil

  defp promote_model_request_options(options) do
    options
    |> promote_provider_option(:reasoning_effort, &normalize_reasoning_effort/1)
    |> promote_provider_option(:service_tier, &normalize_service_tier/1)
  end

  defp promote_provider_option(options, key, normalize) do
    provider_options = Keyword.get(options, :provider_options, [])

    case {Keyword.get(options, key), Keyword.get(provider_options, key)} do
      {nil, value} when not is_nil(value) -> Keyword.put(options, key, normalize.(value))
      _ -> options
    end
  end

  defp normalize_reasoning_effort(value) when value in ["extra high", "extra_high"],
    do: "xhigh"

  defp normalize_reasoning_effort(value), do: value

  defp normalize_service_tier("fast"), do: "priority"
  defp normalize_service_tier(value), do: value

  defp maybe_put_keyword(opts, _key, false, _value), do: opts
  defp maybe_put_keyword(opts, _key, _condition, nil), do: opts
  defp maybe_put_keyword(opts, key, _condition, value), do: Keyword.put(opts, key, value)
end
