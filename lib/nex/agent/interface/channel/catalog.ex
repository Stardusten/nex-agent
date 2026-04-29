defmodule Nex.Agent.Interface.Channel.Catalog do
  @moduledoc """
  Channel type catalog projected from enabled plugin contributions.
  """

  alias Nex.Agent.Extension.Plugin.Catalog, as: PluginCatalog

  @spec all(keyword()) :: [module()]
  def all(opts \\ []) when is_list(opts) do
    opts
    |> channel_contributions()
    |> Enum.map(&spec_module/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec fetch(String.t() | atom(), keyword()) ::
          {:ok, module()} | {:error, {:unknown_channel_type, String.t()}}
  def fetch(type, opts \\ []) when is_list(opts) do
    normalized = normalize_type(type)

    case Enum.find(all(opts), &(normalize_type(&1.type()) == normalized)) do
      nil -> {:error, {:unknown_channel_type, normalized || ""}}
      spec -> {:ok, spec}
    end
  end

  @spec fetch!(String.t() | atom(), keyword()) :: module()
  def fetch!(type, opts \\ []) when is_list(opts) do
    case fetch(type, opts) do
      {:ok, spec} -> spec
      {:error, _reason} -> raise ArgumentError, "unknown channel type: #{inspect(type)}"
    end
  end

  @spec types(keyword()) :: [String.t()]
  def types(opts \\ []), do: Enum.map(all(opts), & &1.type())

  defp channel_contributions(opts) do
    PluginCatalog.contributions("channels", opts)
    |> Enum.sort_by(&contribution_order/1)
  end

  defp contribution_order(%{"attrs" => attrs}) do
    case Map.get(attrs, "order") do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp contribution_order(_contribution), do: 0

  defp spec_module(%{"source" => "builtin", "attrs" => %{} = attrs}) do
    with module_name when is_binary(module_name) <- Map.get(attrs, "spec_module"),
         module <- Module.concat(String.split(module_name, ".")),
         {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :type, 0) do
      module
    else
      _ -> nil
    end
  end

  defp spec_module(_contribution), do: nil

  defp normalize_type(type) when is_atom(type), do: type |> Atom.to_string() |> normalize_type()

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
