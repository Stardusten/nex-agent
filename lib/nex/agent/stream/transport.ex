defmodule Nex.Agent.Stream.Transport do
  @moduledoc false

  alias Nex.Agent.Stream.{FeishuSession, MultiMessageSession, Session}
  alias Nex.Agent.Stream.Result

  @implementations [FeishuSession, MultiMessageSession]

  @spec open_session(term(), String.t(), String.t(), map()) :: {:ok, term()} | :error
  def open_session(key, channel, chat_id, metadata) when is_map(metadata) do
    Enum.find_value(@implementations, :error, fn implementation ->
      case implementation.open_session(key, channel, chat_id, metadata) do
        {:ok, session} -> {:ok, session}
        :error -> false
      end
    end)
  end

  @spec capability(term()) :: Session.capability()
  def capability(%module{} = session), do: module.capability(session)

  @spec handle_event(term(), Nex.Agent.Stream.Event.t()) :: {term(), [Session.action()]}
  def handle_event(%module{} = session, event), do: module.handle_event(session, event)

  @spec finalize_success(term(), Result.t()) :: {term(), [Session.action()], boolean()}
  def finalize_success(%module{} = session, result), do: module.finalize_success(session, result)

  @spec finalize_error(term(), Result.t()) :: {term(), [Session.action()], boolean()}
  def finalize_error(%module{} = session, result), do: module.finalize_error(session, result)

  @spec run_actions(term(), [Session.action()]) :: :ok
  def run_actions(%module{} = _session, actions), do: module.run_actions(actions)
end
