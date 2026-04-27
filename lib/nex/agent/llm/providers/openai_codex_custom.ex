defmodule Nex.Agent.LLM.Providers.OpenAICodexCustom do
  @moduledoc false

  @behaviour Nex.Agent.LLM.ProviderAdapter

  alias Nex.Agent.Auth.Codex
  alias Nex.Agent.LLM.ProviderProfile
  alias Nex.Agent.LLM.Providers.Helpers

  @impl true
  def build_profile(options) do
    %ProviderProfile{
      provider: :openai_codex_custom,
      resolved_provider: :openai,
      base_url: effective_base_url(Keyword.get(options, :base_url)),
      auth_mode: :api_key,
      adapter: __MODULE__
    }
  end

  @impl true
  def default_api_key do
    case System.get_env("OPENAI_CODEX_API_KEY") do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        case Codex.resolve_custom_api_key() do
          {:ok, key} -> key
          _ -> nil
        end
    end
  end

  @impl true
  def default_base_url do
    case Codex.resolve_custom_base_url() do
      {:ok, url} -> url
      _ -> nil
    end
  end

  @impl true
  def default_model, do: "gpt-5.4"

  @impl true
  def prepare_messages_and_options(messages, _profile, options) do
    {instructions, filtered_messages} = Helpers.extract_system_instructions(messages)
    options = promote_model_request_options(options)

    prepared_options =
      options
      |> Keyword.put(:system_prompt, instructions)
      |> Keyword.put(
        :provider_options,
        Keyword.delete(Keyword.get(options, :provider_options, []), :instructions)
      )

    {filtered_messages, prepared_options}
  end

  @impl true
  def provider_options(_profile, options) do
    options
    |> Keyword.get(:provider_options, [])
    |> Keyword.delete(:instructions)
    |> Keyword.put(:auth_mode, :api_key)
    |> Keyword.delete(:access_token)
  end

  defp effective_base_url(nil), do: default_base_url()
  defp effective_base_url(base_url) when is_binary(base_url), do: Helpers.trim_base_url(base_url)

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
end
