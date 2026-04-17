defmodule Nex.Agent.IMIR do
  @moduledoc false

  alias Nex.Agent.IMIR.Parser
  alias Nex.Agent.IMIR.Profiles.{Discord, Feishu}

  @spec new(atom() | map()) :: Parser.t()
  def new(:discord), do: Parser.new(profile: Discord.profile())
  def new(:feishu), do: Parser.new(profile: Feishu.profile())
  def new(profile) when is_map(profile), do: Parser.new(profile: profile)
end
