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

  @spec chunk_message(String.t(), pos_integer()) :: [String.t()]
  def chunk_message(text, max_len) when is_binary(text) and is_integer(max_len) and max_len > 0 do
    text
    |> do_chunk_message(max_len, [])
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @spec split_at_safe_boundary(String.t(), pos_integer()) ::
          {:ok, String.t(), String.t()} | :error
  def split_at_safe_boundary(text, max_len)
      when is_binary(text) and is_integer(max_len) and max_len > 0 do
    if String.length(text) <= max_len do
      :error
    else
      prefix = String.slice(text, 0, max_len)

      prefix
      |> safe_boundary_cut()
      |> case do
        nil ->
          :error

        cut ->
          <<chunk::binary-size(cut), rest::binary>> = text
          {:ok, chunk, rest}
      end
    end
  end

  defp maybe_trim_segment(segment) do
    String.trim(segment)
  end

  defp do_chunk_message("", _max_len, acc), do: acc

  defp do_chunk_message(text, max_len, acc) do
    cond do
      String.trim(text) == "" ->
        acc

      String.length(text) <= max_len ->
        [text | acc]

      true ->
        case split_at_safe_boundary(text, max_len) do
          {:ok, chunk, rest} ->
            do_chunk_message(rest, max_len, [chunk | acc])

          :error ->
            {chunk, rest} = hard_split_balanced(text, max_len)
            do_chunk_message(rest, max_len, [chunk | acc])
        end
    end
  end

  defp safe_boundary_cut(prefix) do
    [
      ["\n\n"],
      ["\n"],
      [". ", "! ", "? ", "; ", ", "],
      [" "]
    ]
    |> Enum.find_value(fn patterns ->
      last_safe_cut(prefix, patterns)
    end)
  end

  defp last_safe_cut(prefix, patterns) do
    patterns
    |> Enum.flat_map(fn pattern ->
      prefix
      |> :binary.matches(pattern)
      |> Enum.map(fn {pos, len} -> pos + len end)
    end)
    |> Enum.sort(:desc)
    |> Enum.find(fn cut ->
      cut > 0 and not in_code_block?(binary_part(prefix, 0, cut))
    end)
  end

  defp hard_split_balanced(text, max_len) do
    probe = String.slice(text, 0, max_len)

    if in_code_block?(probe) and max_len > 8 do
      split_len = max_len - 4
      {chunk, rest} = String.split_at(text, split_len)
      {_in_code?, lang} = fence_state(chunk)
      opener = code_fence_opener(lang)
      {ensure_trailing_newline(chunk) <> "```", opener <> rest}
    else
      String.split_at(text, max_len)
    end
  end

  defp in_code_block?(text) when is_binary(text) do
    {in_code?, _lang} = fence_state(text)
    in_code?
  end

  defp fence_state(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.reduce({false, nil}, fn line, {in_code?, lang} ->
      if fence_line?(line) do
        if in_code? do
          {false, nil}
        else
          {true, fence_lang(line)}
        end
      else
        {in_code?, lang}
      end
    end)
  end

  defp fence_line?(line) do
    line
    |> String.trim_leading()
    |> String.starts_with?("```")
  end

  defp fence_lang(line) do
    line
    |> String.trim_leading()
    |> String.trim_leading("```")
    |> String.trim()
    |> case do
      "" -> nil
      lang -> lang
    end
  end

  defp code_fence_opener(nil), do: "```\n"
  defp code_fence_opener(""), do: "```\n"
  defp code_fence_opener(lang), do: "```#{lang}\n"

  defp ensure_trailing_newline(text) do
    if String.ends_with?(text, "\n") do
      text
    else
      text <> "\n"
    end
  end
end
