defmodule Nex.Agent.Interface.IMIR do
  @moduledoc false

  alias Nex.Agent.Interface.Channel.Catalog
  alias Nex.Agent.Interface.IMIR.Parser

  @spec new(atom() | String.t() | map()) :: Parser.t()
  def new(type) when is_atom(type) or is_binary(type) do
    spec = Catalog.fetch!(type)

    case spec.im_profile() do
      profile when is_map(profile) -> Parser.new(profile: profile)
      nil -> raise ArgumentError, "channel type #{inspect(type)} does not expose an IM IR profile"
    end
  end

  def new(profile) when is_map(profile), do: Parser.new(profile: profile)
end
