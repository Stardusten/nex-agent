defmodule Nex.Agent.Conversation.Command do
  @moduledoc """
  Shared command resolution and execution entry point.
  """

  alias Nex.Agent.Conversation.Command.{Catalog, Invocation, Parser}
  alias Nex.Agent.Interface.Inbound.Envelope

  @type resolution :: {:command, Invocation.t(), map()} | :no_match

  @spec resolve(Envelope.t(), map()) :: resolution()
  def resolve(%Envelope{command: %Invocation{} = invocation, channel: channel}, runtime_commands) do
    case command_definition(invocation.name, runtime_commands) do
      nil -> :no_match
      definition -> {:command, invocation, definition_for_channel(definition, channel)}
    end
  end

  def resolve(%Envelope{text: text, channel: channel}, runtime_commands) do
    case Parser.parse(text) do
      {:ok, %Invocation{} = invocation} ->
        case command_definition(invocation.name, runtime_commands) do
          nil -> :no_match
          definition -> {:command, invocation, definition_for_channel(definition, channel)}
        end

      :no_match ->
        :no_match
    end
  end

  @spec catalog() :: [Catalog.definition()]
  def catalog, do: Catalog.definitions()

  @spec command_definition(String.t(), [map()] | nil) :: map() | nil
  def command_definition(name, runtime_commands) when is_binary(name) do
    runtime_commands
    |> List.wrap()
    |> Enum.find(&(Map.get(&1, "name") == name))
  end

  defp definition_for_channel(definition, channel) do
    channels = Map.get(definition, "channels", [])

    if channels == [] or to_string(channel) in channels do
      definition
    else
      nil
    end
  end
end
