defmodule Nex.Agent.Turn.LLM.ProviderRegistry do
  @moduledoc false

  alias Nex.Agent.Extension.Plugin.Catalog, as: PluginCatalog
  alias Nex.Agent.Turn.LLM.Providers

  @provider_atoms %{
    "anthropic" => :anthropic,
    "openai" => :openai,
    "openai-compatible" => :openai_compatible,
    "openrouter" => :openrouter,
    "ollama" => :ollama,
    "openai-codex" => :openai_codex,
    "openai-codex-custom" => :openai_codex_custom
  }

  @spec adapter_for(atom(), keyword()) :: module()
  def adapter_for(provider, opts \\ [])

  def adapter_for(provider, opts) when is_atom(provider) and is_list(opts) do
    provider
    |> provider_type()
    |> then(&Map.get(adapter_map(opts), &1, Providers.Default))
  end

  def adapter_for(_provider, _opts), do: Providers.Default

  @spec known_providers(keyword()) :: [atom()]
  def known_providers(opts \\ []) do
    opts
    |> known_provider_types()
    |> Enum.map(&provider_atom/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec known_provider_types(keyword()) :: [String.t()]
  def known_provider_types(opts \\ []) do
    opts
    |> adapter_map()
    |> Map.keys()
  end

  @spec provider_available?(String.t() | atom(), keyword()) :: boolean()
  def provider_available?(provider, opts \\ [])

  def provider_available?(provider, opts) when is_atom(provider) and is_list(opts),
    do: provider in known_providers(opts)

  def provider_available?(provider, opts) when is_binary(provider) and is_list(opts),
    do: normalize_type(provider) in known_provider_types(opts)

  def provider_available?(_provider, _opts), do: false

  @spec provider_atom(String.t() | atom() | nil) :: atom() | nil
  def provider_atom(provider) when is_atom(provider), do: provider

  def provider_atom(provider) when is_binary(provider) do
    provider
    |> normalize_type()
    |> then(&Map.get(@provider_atoms, &1))
  end

  def provider_atom(_provider), do: nil

  @spec provider_type(atom() | String.t() | nil) :: String.t() | nil
  def provider_type(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> String.replace("_", "-")
  end

  def provider_type(provider) when is_binary(provider), do: normalize_type(provider)
  def provider_type(_provider), do: nil

  defp adapter_map(opts) do
    PluginCatalog.contributions("providers", opts)
    |> Enum.reduce(%{}, fn contribution, acc ->
      with {:ok, type} <- contribution_type(contribution),
           {:ok, module} <- adapter_module(contribution) do
        Map.put(acc, type, module)
      else
        _ -> acc
      end
    end)
  end

  defp contribution_type(%{"attrs" => %{} = attrs}) do
    case normalize_type(Map.get(attrs, "type")) do
      nil -> :error
      type -> {:ok, type}
    end
  end

  defp contribution_type(_contribution), do: :error

  defp adapter_module(%{"source" => "builtin", "attrs" => %{} = attrs}) do
    with module_name when is_binary(module_name) <- Map.get(attrs, "adapter_module"),
         module <- Module.concat(String.split(module_name, ".")),
         {:module, ^module} <- Code.ensure_loaded(module) do
      {:ok, module}
    else
      _ -> :error
    end
  end

  defp adapter_module(_contribution), do: :error

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_type(_type), do: nil
end
