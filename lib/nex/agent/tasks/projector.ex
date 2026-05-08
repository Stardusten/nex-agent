defmodule Nex.Agent.Tasks.Projector do
  @moduledoc false

  alias Nex.Agent.Tasks.Store

  @spec runtime_data(keyword()) :: map()
  def runtime_data(opts \\ []) do
    workspace_tasks = Store.read_raw(opts)
    plugin_tasks = plugin_tasks(Keyword.get(opts, :plugin_data) || %{})
    definitions = workspace_tasks ++ plugin_tasks
    diagnostics = []

    %{
      definitions: definitions,
      diagnostics: diagnostics,
      path: Store.path(opts),
      hash: hash({definitions, diagnostics})
    }
  end

  defp plugin_tasks(plugin_data) do
    contributions =
      Map.get(plugin_data, :contributions) || Map.get(plugin_data, "contributions") || %{}

    Map.get(contributions, :tasks) || Map.get(contributions, "tasks") || []
  end

  defp hash(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
  end
end
