defmodule Nex.Agent.Stream.Sink do
  @moduledoc false

  @callback handle_event({:text, String.t()} | :finish | {:error, String.t()}, state :: term()) ::
              {:ok, term()} | {:error, term()}
end
