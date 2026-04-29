defmodule Nex.Agent.Extension.Plugin do
  @moduledoc """
  Plugin runtime host facade.
  """

  alias Nex.Agent.Extension.Plugin.Catalog

  @spec runtime_data(keyword()) :: map()
  def runtime_data(opts \\ []), do: Catalog.runtime_data(opts)
end
