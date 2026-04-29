defmodule Nex.Agent.Channel.Catalog do
  @moduledoc """
  Built-in channel type catalog.
  """

  @spec all() :: [module()]
  def all do
    [
      Nex.Agent.Channel.Specs.Feishu,
      Nex.Agent.Channel.Specs.Discord
    ]
  end

  @spec fetch(String.t() | atom()) ::
          {:ok, module()} | {:error, {:unknown_channel_type, String.t()}}
  def fetch(type) do
    normalized = normalize_type(type)

    case Enum.find(all(), &(normalize_type(&1.type()) == normalized)) do
      nil -> {:error, {:unknown_channel_type, normalized || ""}}
      spec -> {:ok, spec}
    end
  end

  @spec fetch!(String.t() | atom()) :: module()
  def fetch!(type) do
    case fetch(type) do
      {:ok, spec} -> spec
      {:error, _reason} -> raise ArgumentError, "unknown channel type: #{inspect(type)}"
    end
  end

  @spec types() :: [String.t()]
  def types, do: Enum.map(all(), & &1.type())

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
