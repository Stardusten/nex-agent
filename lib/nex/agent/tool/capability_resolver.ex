defmodule Nex.Agent.Tool.CapabilityResolver do
  @moduledoc false

  alias Nex.Agent.Config
  alias Nex.Agent.LLM.ProviderProfile
  alias Nex.Agent.Tool.Capability
  alias Nex.Agent.Tool.Capabilities.ImageGeneration.OpenAICodexAdapter, as: ImageGenerationOpenAICodexAdapter
  alias Nex.Agent.Tool.Capabilities.WebSearch.LocalAdapter, as: WebSearchLocalAdapter
  alias Nex.Agent.Tool.Capabilities.WebSearch.OpenAICodexAdapter, as: WebSearchOpenAICodexAdapter

  @builtin_tool_types ~w(web_search_preview file_search mcp x_search)
  @spec resolve(module(), keyword() | map()) :: Capability.t()
  def resolve(module, opts \\ []) when is_atom(module) do
    tool_name = safe_tool_name(module)

    profile = provider_profile(opts)
    config = config_from_opts(opts)

    case tool_name do
      "image_generation" ->
        resolve_image_generation(module, profile, config)

      "web_search" ->
        resolve_web_search(module, profile, config)

      _ ->
        %Capability{
          tool_name: tool_name,
          strategy: :local,
          definition: local_definition(module),
          provider_native: nil
        }
    end
  end

  @spec builtin_tool_definition?(map()) :: boolean()
  def builtin_tool_definition?(tool) when is_map(tool) do
    type = Map.get(tool, "type") || Map.get(tool, :type)
    is_binary(type) and type in @builtin_tool_types
  end

  def builtin_tool_definition?(_tool), do: false

  defp resolve_image_generation(module, profile, config) do
    capability = Config.image_generation_capability(config)
    adapter = image_generation_adapter(capability, profile)

    case adapter do
      nil -> disabled_capability("image_generation")
      adapter when is_atom(adapter) -> apply(adapter, :resolve, [module, profile, capability])
    end
  end

  defp resolve_web_search(module, profile, config) do
    capability = Config.web_search_capability(config)
    mode = Map.get(capability, "mode", "live")
    adapter = web_search_adapter(capability, profile)

    cond do
      mode == "disabled" ->
        disabled_web_search_capability()

      is_nil(adapter) ->
        disabled_web_search_capability()

      true ->
        apply(adapter, :resolve, [module, profile, capability])
    end
  end

  defp disabled_web_search_capability do
    disabled_capability("web_search")
  end

  defp native_web_search_supported?(%ProviderProfile{} = profile) do
    profile.provider == :openai_codex and
      profile.auth_mode == :oauth and
      profile.base_url == ProviderProfile.default_base_url(:openai_codex)
  end

  defp openai_codex_backend_available? do
    is_binary(ProviderProfile.default_api_key(:openai_codex)) and
      ProviderProfile.default_base_url(:openai_codex) not in [nil, ""]
  end

  defp web_search_adapter(capability, profile) do
    strategy = Map.get(capability, "strategy", "auto")
    backend = Map.get(capability, "backend", "auto")

    case {backend, strategy} do
      {"duckduckgo", _} ->
        WebSearchLocalAdapter

      {"openai_codex", _} ->
        if openai_codex_backend_available?(), do: WebSearchOpenAICodexAdapter

      {"auto", "local"} ->
        WebSearchLocalAdapter

      {"auto", "provider_native"} ->
        if openai_codex_backend_available?(), do: WebSearchOpenAICodexAdapter

      {"auto", "auto"} ->
        if native_web_search_supported?(profile),
          do: WebSearchOpenAICodexAdapter,
          else: WebSearchLocalAdapter

      _ ->
        nil
    end
  end

  defp image_generation_adapter(capability, profile) do
    strategy = Map.get(capability, "strategy", "auto")
    backend = Map.get(capability, "backend", "auto")

    case {backend, strategy} do
      {"openai_codex", _} ->
        if openai_codex_backend_available?(), do: ImageGenerationOpenAICodexAdapter

      {"auto", "provider_native"} ->
        if openai_codex_backend_available?(), do: ImageGenerationOpenAICodexAdapter

      {"auto", "auto"} ->
        if native_web_search_supported?(profile), do: ImageGenerationOpenAICodexAdapter

      _ ->
        nil
    end
  end

  defp disabled_capability(tool_name) do
    %Capability{
      tool_name: tool_name,
      strategy: :disabled,
      definition: nil,
      provider_native: nil
    }
  end

  defp provider_profile(opts) do
    config = config_from_opts(opts)

    provider =
      opt_value(opts, :provider) ||
        provider_from_config(config)

    profile_opts =
      []
      |> maybe_put_opt(:base_url, opt_value(opts, :base_url) || base_url_from_config(config, provider))

    ProviderProfile.for(provider || :anthropic, profile_opts)
  end

  defp config_from_opts(opts) do
    case opt_value(opts, :config) do
      %Config{} = config -> config
      _ -> nil
    end
  end

  defp provider_from_config(%Config{} = config), do: Config.provider_to_atom(config.provider)
  defp provider_from_config(_config), do: nil

  defp base_url_from_config(%Config{} = config, provider) when not is_nil(provider) do
    Config.get_base_url(config, provider_name(provider))
  end

  defp base_url_from_config(_config, _provider), do: nil

  defp provider_name(provider) when is_atom(provider), do: Atom.to_string(provider) |> String.replace("_", "-")
  defp provider_name(provider) when is_binary(provider), do: provider

  defp local_definition(module) do
    if function_exported?(module, :definition, 0) do
      module.definition()
    else
      nil
    end
  end

  defp safe_tool_name(module) do
    cond do
      function_exported?(module, :name, 0) ->
        module.name()

      function_exported?(module, :definition, 0) ->
        module.definition()
        |> then(&(Map.get(&1, :name) || Map.get(&1, "name")))
        |> to_string()

      true ->
        inspect(module)
    end
  end

  defp opt_value(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt_value(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  defp opt_value(_opts, _key), do: nil

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
