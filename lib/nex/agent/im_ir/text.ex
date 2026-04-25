defmodule Nex.Agent.IMIR.Text do
  @moduledoc false

  @new_message_token "<newmsg/>"

  @spec split_messages(String.t()) :: [String.t()]
  def split_messages(text) when is_binary(text) do
    text
    |> String.split(@new_message_token, trim: false)
    |> Enum.map(&maybe_trim_segment/1)
    |> Enum.reject(&(&1 == ""))
  end

  @spec split_complete_messages(String.t()) :: {[String.t()], String.t()}
  def split_complete_messages(text) when is_binary(text) do
    parts = String.split(text, @new_message_token, trim: false)

    case parts do
      [remainder] ->
        {[], maybe_trim_segment(remainder)}

      _ ->
        {segments, [remainder]} = Enum.split(parts, -1)

        complete =
          segments
          |> Enum.map(&maybe_trim_segment/1)
          |> Enum.reject(&(&1 == ""))

        {complete, maybe_trim_segment(remainder)}
    end
  end

  defp maybe_trim_segment(segment) do
    String.trim(segment)
  end
end
