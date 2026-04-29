defmodule Nex.Agent.Turn.LLM.Behaviour do
  @moduledoc """
  LLM provider behaviour
  """

  @callback stream(messages :: [map()], options :: map() | Keyword.t(), fun()) ::
              :ok | {:error, term()}
  @callback tools() :: [map()]
end
