defmodule Nex.Agent.IMIR.Text do
  @moduledoc false

  @new_message_token "<newmsg/>"

  @spec split_messages(String.t()) :: [String.t()]
  def split_messages(text) when is_binary(text) do
    {segments, current, _in_code?} =
      text
      |> String.split("\n", trim: false)
      |> Enum.reduce({[], [], false}, fn line, {segments, current, in_code?} ->
        cond do
          line == @new_message_token and not in_code? ->
            segment = current |> Enum.join("\n") |> maybe_trim_segment()
            {append_segment(segments, segment), [], in_code?}

          String.starts_with?(line, "```") ->
            {segments, current ++ [line], not in_code?}

          true ->
            {segments, current ++ [line], in_code?}
        end
      end)

    current
    |> Enum.join("\n")
    |> maybe_trim_segment()
    |> then(&append_segment(segments, &1))
  end

  @spec split_complete_messages(String.t()) :: {[String.t()], String.t()}
  def split_complete_messages(text) when is_binary(text) do
    {segments, current, _in_code?} =
      text
      |> String.split("\n", trim: false)
      |> Enum.reduce({[], [], false}, fn line, {segments, current, in_code?} ->
        cond do
          line == @new_message_token and not in_code? ->
            segment = current |> Enum.join("\n") |> maybe_trim_segment()
            {append_segment(segments, segment), [], in_code?}

          String.starts_with?(line, "```") ->
            {segments, current ++ [line], not in_code?}

          true ->
            {segments, current ++ [line], in_code?}
        end
      end)

    remainder =
      current
      |> Enum.join("\n")
      |> maybe_trim_segment()

    {segments, remainder}
  end

  defp maybe_trim_segment(segment) do
    segment
    |> String.trim()
  end

  defp append_segment(segments, ""), do: segments
  defp append_segment(segments, segment), do: segments ++ [segment]
end
