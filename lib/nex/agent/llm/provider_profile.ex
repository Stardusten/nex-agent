defmodule Nex.Agent.LLM.ProviderProfile do
  @moduledoc false

  alias Nex.Agent.Auth.Codex

  @openrouter_referer "https://nex.dev"
  @openrouter_title "Nex Agent"
  @ollama_placeholder_api_key "ollama"
  @codex_base_url "https://chatgpt.com/backend-api/codex"
  @codex_fallback_instructions "You are a helpful coding assistant."

  defstruct provider: :anthropic,
            resolved_provider: :anthropic,
            base_url: nil,
            auth_mode: nil

  @type t :: %__MODULE__{
          provider: atom(),
          resolved_provider: atom(),
          base_url: String.t() | nil,
          auth_mode: atom() | nil
        }

  @spec for(atom(), keyword()) :: t()
  def for(provider, options \\ []) do
    provider = normalize_provider(provider)
    base_url = effective_base_url(provider, Keyword.get(options, :base_url))

    %__MODULE__{
      provider: provider,
      resolved_provider: resolved_provider(provider),
      base_url: base_url,
      auth_mode: auth_mode(provider, base_url)
    }
  end

  @spec default_api_key(atom()) :: String.t() | nil
  def default_api_key(:openai_codex) do
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

  def default_api_key(:openai_codex_custom) do
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

  def default_api_key(_), do: nil

  @spec default_base_url(atom()) :: String.t() | nil
  def default_base_url(:openai_codex), do: Codex.default_base_url()

  def default_base_url(:openai_codex_custom) do
    case Codex.resolve_custom_base_url() do
      {:ok, url} -> url
      _ -> nil
    end
  end

  def default_base_url(_), do: nil

  @spec prepare_messages_and_options([map()], t(), keyword()) :: {[map()], keyword()}
  def prepare_messages_and_options(messages, %__MODULE__{provider: :openai_codex} = profile, options) do
    {instructions, filtered_messages} = extract_system_instructions(messages)
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

  def prepare_messages_and_options(messages, %__MODULE__{provider: :openai_codex_custom}, options) do
    {instructions, filtered_messages} = extract_system_instructions(messages)

    prepared_options =
      options
      |> Keyword.put(:system_prompt, instructions)
      |> Keyword.put(:provider_options, Keyword.delete(Keyword.get(options, :provider_options, []), :instructions))

    {filtered_messages, prepared_options}
  end

  def prepare_messages_and_options(messages, _profile, options), do: {messages, options}

  @spec api_key_config(t(), keyword()) :: {String.t() | nil, boolean()}
  def api_key_config(%__MODULE__{provider: :ollama}, _options), do: {@ollama_placeholder_api_key, true}

  def api_key_config(%__MODULE__{provider: :openai_codex, auth_mode: :oauth}, _options),
    do: {nil, false}

  def api_key_config(%__MODULE__{}, options) do
    api_key = Keyword.get(options, :api_key)
    {api_key, present?(api_key)}
  end

  @spec provider_options(t(), keyword()) :: keyword()
  def provider_options(%__MODULE__{provider: :openai_codex, auth_mode: :oauth}, options) do
    base = Keyword.get(options, :provider_options, [])
    access_token = Keyword.get(options, :api_key)
    instructions = Keyword.get(base, :instructions, @codex_fallback_instructions)

    base
    |> Keyword.put(:instructions, instructions)
    |> Keyword.put(:auth_mode, :oauth)
    |> maybe_put_keyword(:access_token, present?(access_token), access_token)
  end

  def provider_options(%__MODULE__{provider: :openai_codex, auth_mode: :api_key}, options) do
    options
    |> Keyword.get(:provider_options, [])
    |> Keyword.delete(:instructions)
    |> Keyword.put(:auth_mode, :api_key)
    |> Keyword.delete(:access_token)
  end

  def provider_options(%__MODULE__{provider: :openai_codex_custom}, options) do
    options
    |> Keyword.get(:provider_options, [])
    |> Keyword.delete(:instructions)
    |> Keyword.put(:auth_mode, :api_key)
    |> Keyword.delete(:access_token)
  end

  def provider_options(%__MODULE__{resolved_provider: :openrouter}, _options),
    do: [app_referer: @openrouter_referer, app_title: @openrouter_title]

  def provider_options(%__MODULE__{}, _options), do: []

  @spec model_spec(t(), String.t()) :: String.t() | map()
  def model_spec(%__MODULE__{} = profile, model) when is_binary(model) do
    if present?(profile.base_url) or profile.provider in [:openrouter, :ollama, :openai_codex, :openai_codex_custom] do
      %{id: model, provider: profile.resolved_provider, base_url: profile.base_url}
    else
      "#{profile.resolved_provider}:#{model}"
    end
  end

  defp extract_system_instructions(messages) do
    {system_messages, other_messages} =
      Enum.split_with(messages, fn message -> message["role"] == "system" end)

    instructions =
      system_messages
      |> Enum.map(&message_content_to_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> case do
        "" -> @codex_fallback_instructions
        text -> text
      end

    {instructions, other_messages}
  end

  defp message_content_to_text(%{"content" => content}), do: content_to_text(content)
  defp message_content_to_text(_), do: ""

  defp content_to_text(content) when is_binary(content), do: String.trim(content)

  defp content_to_text(content) when is_list(content) do
    content
    |> Enum.map(&content_part_to_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp content_to_text(_), do: ""

  defp content_part_to_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp content_part_to_text(%{type: "text", text: text}) when is_binary(text), do: text
  defp content_part_to_text(%{"text" => text}) when is_binary(text), do: text
  defp content_part_to_text(%{text: text}) when is_binary(text), do: text
  defp content_part_to_text(part) when is_binary(part), do: part
  defp content_part_to_text(_), do: ""

  defp normalize_provider(provider) when is_atom(provider), do: provider
  defp normalize_provider(_), do: :anthropic

  defp resolved_provider(:openai_codex), do: :openai
  defp resolved_provider(:openai_codex_custom), do: :openai
  defp resolved_provider(:ollama), do: :openai
  defp resolved_provider(provider), do: provider

  defp effective_base_url(:openai_codex, nil), do: @codex_base_url
  defp effective_base_url(:openai_codex, base_url), do: String.trim_trailing(base_url, "/")
  defp effective_base_url(:openai_codex_custom, nil), do: codex_custom_base_url()
  defp effective_base_url(:openai_codex_custom, base_url), do: String.trim_trailing(base_url, "/")
  defp effective_base_url(:openrouter, nil), do: "https://openrouter.ai/api/v1"
  defp effective_base_url(:ollama, nil), do: "http://localhost:11434/v1"
  defp effective_base_url(:ollama, base_url), do: normalize_ollama_base_url(base_url)
  defp effective_base_url(_provider, base_url), do: base_url

  defp auth_mode(:openai_codex, @codex_base_url), do: :oauth
  defp auth_mode(:openai_codex, base_url) when is_binary(base_url), do: :api_key
  defp auth_mode(:openai_codex_custom, _base_url), do: :api_key
  defp auth_mode(_provider, _base_url), do: nil

  defp maybe_put_keyword(opts, _key, false, _value), do: opts
  defp maybe_put_keyword(opts, _key, _condition, nil), do: opts
  defp maybe_put_keyword(opts, key, _condition, value), do: Keyword.put(opts, key, value)

  defp present?(value) when value in [nil, "", []], do: false
  defp present?(_), do: true

  defp normalize_ollama_base_url(nil), do: "http://localhost:11434/v1"

  defp normalize_ollama_base_url(base_url) do
    base_url = String.trim_trailing(base_url, "/")
    if String.ends_with?(base_url, "/v1"), do: base_url, else: base_url <> "/v1"
  end

  defp codex_custom_base_url do
    case Codex.resolve_custom_base_url() do
      {:ok, url} -> url
      _ -> nil
    end
  end
end
