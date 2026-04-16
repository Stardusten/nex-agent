defmodule Nex.Agent.Stream.Session do
  @moduledoc false

  alias Nex.Agent.Stream.Event
  alias Nex.Agent.Stream.Result

  @type capability :: :native_stream | :edit_message | :multi_message

  @type action ::
          {:publish, String.t(), String.t(), String.t(), map()}
          | {:update_card, String.t(), String.t()}

  @callback capability(term()) :: capability()

  @callback handle_event(term(), Event.t()) :: {term(), [action()]}

  @callback finalize_success(term(), Result.t()) :: {term(), [action()], boolean()}

  @callback finalize_error(term(), Result.t()) :: {term(), [action()], boolean()}

  @callback open_session(term(), String.t(), String.t(), map()) :: {:ok, term()} | :error

  @callback run_actions([action()]) :: :ok
end
