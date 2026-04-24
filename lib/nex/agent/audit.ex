defmodule Nex.Agent.Audit do
  @moduledoc false

  alias Nex.Agent.ControlPlane.Query

  alias Nex.Agent.ControlPlane.Log, as: ControlPlaneLog
  require ControlPlaneLog

  @spec append(String.t(), map(), keyword()) :: :ok
  def append(event, payload, opts \\ []) when is_binary(event) and is_map(payload) do
    case ControlPlaneLog.info(event, payload, opts) do
      {:ok, observation} -> Nex.Agent.Admin.publish_observation(observation)
      {:error, _reason} -> :ok
    end

    :ok
  end

  @spec recent(keyword()) :: [map()]
  def recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    opts
    |> Keyword.put(:limit, limit)
    |> Query.recent_events()
  end
end
