defmodule Nex.Agent.Conversation.Command.Catalog do
  @moduledoc """
  Unified user-facing slash command catalog.

  This catalog is the truth source for cross-platform command behavior.
  Channels may project these commands into native platform surfaces, but the
  execution contract remains owned by the shared command layer.
  """

  @type command_name :: String.t()

  alias Nex.Agent.Extension.Plugin.Catalog, as: PluginCatalog

  @type definition :: %{
          required(:name) => command_name(),
          required(:description) => String.t(),
          required(:usage) => String.t(),
          required(:bypass_busy?) => boolean(),
          required(:native_enabled?) => boolean(),
          required(:handler) => atom(),
          optional(:channels) => [String.t()]
        }

  @handler_order ~w(new stop commands status model queue btw)
  @handler_ids MapSet.new(@handler_order)

  @spec definitions(keyword()) :: [definition()]
  def definitions(opts \\ []) do
    opts
    |> runtime_definitions()
    |> Enum.map(&definition_from_runtime/1)
  end

  @spec runtime_definitions(keyword()) :: [map()]
  def runtime_definitions(opts \\ []) do
    "commands"
    |> PluginCatalog.contributions(opts)
    |> Enum.flat_map(&runtime_definition/1)
    |> Enum.uniq_by(&Map.fetch!(&1, "name"))
    |> Enum.sort_by(&definition_rank/1)
  end

  @spec get(String.t(), keyword()) :: definition() | nil
  def get(name, opts \\ []) when is_binary(name) do
    Enum.find(definitions(opts), &(Map.get(&1, :name) == name))
  end

  defp runtime_definition(%{"source" => "builtin", "attrs" => %{} = attrs}) do
    name = normalized_string(Map.get(attrs, "name"))
    handler = normalized_string(Map.get(attrs, "handler", name))

    cond do
      name == "" ->
        []

      not MapSet.member?(@handler_ids, handler) ->
        []

      true ->
        [
          %{
            "name" => name,
            "description" => normalized_string(Map.get(attrs, "description")),
            "usage" => normalized_usage(Map.get(attrs, "usage"), name),
            "bypass_busy?" => truthy?(Map.get(attrs, "bypass_busy?", true)),
            "native_enabled?" => truthy?(Map.get(attrs, "native_enabled?", true)),
            "handler" => handler,
            "channels" => normalize_channels(Map.get(attrs, "channels", []))
          }
        ]
    end
  end

  defp runtime_definition(_contribution), do: []

  defp definition_from_runtime(%{} = definition) do
    %{
      name: Map.get(definition, "name", ""),
      description: Map.get(definition, "description", ""),
      usage: Map.get(definition, "usage", ""),
      bypass_busy?: Map.get(definition, "bypass_busy?", false) == true,
      native_enabled?: Map.get(definition, "native_enabled?", false) == true,
      handler:
        definition
        |> Map.get("handler", "")
        |> String.to_atom(),
      channels: normalize_channels(Map.get(definition, "channels", []))
    }
  end

  defp definition_rank(%{"handler" => handler}) do
    case Enum.find_index(@handler_order, &(&1 == handler)) do
      nil -> length(@handler_order)
      index -> index
    end
  end

  defp normalized_usage(nil, name), do: "/#{name}"
  defp normalized_usage("", name), do: "/#{name}"
  defp normalized_usage(usage, _name), do: normalized_string(usage)

  defp normalize_channels(channels) when is_list(channels) do
    channels
    |> Enum.map(&normalized_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_channels(_channels), do: []

  defp normalized_string(value) when is_binary(value), do: String.trim(value)
  defp normalized_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalized_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalized_string(_value), do: ""

  defp truthy?(value) when value in [true, "true"], do: true
  defp truthy?(_value), do: false
end
