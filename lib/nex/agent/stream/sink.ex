defmodule Nex.Agent.Stream.Sink do
  @moduledoc false

  alias Nex.Agent.Stream.Event

  @callback handle_event(Event.t(), state :: term()) :: {:ok, term()} | {:error, term()}
end
