defmodule Nex.Agent.Conversation.Command.Parser do
  @moduledoc """
  Parse slash-prefixed user text into a known command invocation.

  Unknown slash-prefixed input intentionally returns `:no_match` so the text can
  continue through the normal LLM path unchanged.
  """

  alias Nex.Agent.Conversation.Command.{Catalog, Invocation}

  @spec parse(String.t()) :: {:ok, Invocation.t()} | :no_match
  def parse(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        :no_match

      not String.starts_with?(trimmed, "/") ->
        :no_match

      true ->
        case split(trimmed) do
          [name | args] ->
            normalized = String.downcase(name)

            case Catalog.get(normalized) do
              nil ->
                :no_match

              _definition ->
                {:ok, %Invocation{name: normalized, args: args, raw: trimmed, source: :text}}
            end

          _ ->
            :no_match
        end
    end
  end

  def parse(_text), do: :no_match

  defp split("/" <> rest) do
    rest
    |> String.split(~r/\s+/, trim: true)
  end

  defp split(_text), do: []
end
