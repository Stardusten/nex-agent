defmodule Nex.Agent.IMIR.Parser do
  @moduledoc false

  alias Nex.Agent.IMIR.Block
  alias Nex.Agent.IMIR.Profiles.Feishu

  @default_profile Feishu.profile()

  @enforce_keys [:profile]
  defstruct profile: @default_profile, buffer: ""

  @type t :: %__MODULE__{
          profile: map(),
          buffer: String.t()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      profile: Keyword.get(opts, :profile, @default_profile),
      buffer: ""
    }
  end

  @spec push(t(), String.t()) :: {t(), [Block.t()]}
  def push(%__MODULE__{} = parser, chunk) when is_binary(chunk) do
    buffer = parser.buffer <> chunk
    {emitted, rest} = extract_complete_blocks(buffer, parser.profile)
    {%{parser | buffer: rest}, emitted}
  end

  @spec flush(t()) :: {t(), [Block.t()]}
  def flush(%__MODULE__{} = parser) do
    blocks = parse_full(parser.buffer, parser.profile) |> Enum.reject(&blank_paragraph?/1)
    {%{parser | buffer: ""}, blocks}
  end

  defp extract_complete_blocks(buffer, profile) do
    {blocks, partial_tail, state} = parse_lines(buffer, profile)

    cond do
      partial_tail == "" and not state.in_code? ->
        emitted = finalize_pending(blocks, state) |> Enum.reject(&blank_paragraph?/1)
        {emitted, ""}

      new_message_prefix?(partial_tail, profile) and not state.in_code? ->
        emitted = flush_pending(blocks, state) |> Enum.reject(&blank_paragraph?/1)
        {emitted, partial_tail}

      true ->
        {Enum.reject(blocks, &blank_paragraph?/1), state_to_buffer(state, partial_tail)}
    end
  end

  defp parse_full(text, profile) when is_binary(text) do
    {blocks, state} =
      text
      |> normalize_new_message_tokens(profile)
      |> String.split("\n", trim: false)
      |> Enum.reduce({[], blank_state()}, fn line, {blocks, state} ->
        consume_line(blocks, state, line, profile)
      end)

    finalize_pending(blocks, state) |> Enum.reject(&blank_paragraph?/1)
  end

  defp parse_lines(text, profile) do
    {complete_lines, partial_tail} =
      text
      |> normalize_new_message_tokens(profile)
      |> split_complete_lines()

    Enum.reduce(complete_lines, {[], partial_tail, blank_state()}, fn line,
                                                                      {blocks, tail, state} ->
      {blocks, state} = consume_line(blocks, state, line, profile)
      {blocks, tail, state}
    end)
  end

  defp split_complete_lines(text) do
    lines = String.split(text, "\n", trim: false)

    if String.ends_with?(text, "\n") do
      {Enum.drop(lines, -1), ""}
    else
      case Enum.split(lines, max(length(lines) - 1, 0)) do
        {complete_lines, [tail]} -> {complete_lines, tail}
        {complete_lines, []} -> {complete_lines, ""}
      end
    end
  end

  defp consume_line(blocks, state, line, profile) do
    cond do
      line == profile[:new_message_token] ->
        blocks =
          blocks
          |> finalize_pending(state)
          |> Kernel.++([
            %Block{
              type: :new_message,
              text: "",
              canonical_text: profile[:new_message_token],
              complete?: true
            }
          ])

        {blocks, blank_state()}

      state.in_code? ->
        consume_code_line(blocks, state, line)

      String.starts_with?(line, "```") ->
        {flush_pending(blocks, state),
         %{blank_state() | in_code?: true, code_lang: parse_code_lang(line), code_lines: [line]}}

      tables_enabled?(profile) and table_row?(line) ->
        blocks = flush_pending_if_not(blocks, state, :table)
        state = append_table_line(reset_pending_if_needed(state, :table), line)
        {blocks, state}

      heading?(line) ->
        block = heading_block(line)
        {flush_pending(blocks, state) ++ [block], blank_state()}

      list_item?(line) ->
        blocks = flush_pending_if_not(blocks, state, :list)
        state = append_list_line(reset_pending_if_needed(state, :list), line)
        {blocks, state}

      quote_line?(line) ->
        blocks = flush_pending_if_not(blocks, state, :quote)
        state = append_quote_line(reset_pending_if_needed(state, :quote), line)
        {blocks, state}

      String.trim(line) == "" ->
        {flush_pending(blocks, state), blank_state()}

      true ->
        blocks = flush_pending_if_not(blocks, state, :paragraph)
        state = append_paragraph_line(reset_pending_if_needed(state, :paragraph), line)
        {blocks, state}
    end
  end

  defp consume_code_line(blocks, state, line) do
    code_lines = state.code_lines ++ [line]

    if String.starts_with?(line, "```") do
      block = code_block(code_lines, state.code_lang)
      {blocks ++ [block], blank_state()}
    else
      {blocks, %{state | code_lines: code_lines}}
    end
  end

  defp blank_state do
    %{
      pending: nil,
      in_code?: false,
      code_lang: nil,
      code_lines: []
    }
  end

  defp flush_pending(blocks, %{pending: nil}), do: blocks

  defp flush_pending(blocks, state) do
    case pending_block(state.pending) do
      nil -> blocks
      block -> blocks ++ [block]
    end
  end

  defp flush_pending_if_not(blocks, %{pending: {kind, _}}, kind), do: blocks
  defp flush_pending_if_not(blocks, state, _kind), do: flush_pending(blocks, state)

  defp reset_pending_if_needed(%{pending: {kind, _}} = state, kind), do: state
  defp reset_pending_if_needed(_state, kind), do: %{blank_state() | pending: {kind, []}}

  defp append_list_line(state, line) do
    {:list, items} = state.pending
    %{state | pending: {:list, items ++ [line]}}
  end

  defp append_quote_line(state, line) do
    {:quote, lines} = state.pending
    %{state | pending: {:quote, lines ++ [line]}}
  end

  defp append_table_line(state, line) do
    {:table, rows} = state.pending
    %{state | pending: {:table, rows ++ [line]}}
  end

  defp append_paragraph_line(state, line) do
    {:paragraph, lines} = state.pending
    %{state | pending: {:paragraph, lines ++ [line]}}
  end

  defp pending_block(nil), do: nil

  defp pending_block({:paragraph, lines}) do
    text = Enum.join(lines, "\n")
    %Block{type: :paragraph, text: text, canonical_text: text, complete?: true}
  end

  defp pending_block({:list, items}) do
    text = Enum.join(items, "\n")
    %Block{type: :list, text: text, items: items, canonical_text: text, complete?: true}
  end

  defp pending_block({:quote, lines}) do
    text = Enum.join(lines, "\n")
    %Block{type: :quote, text: text, canonical_text: text, complete?: true}
  end

  defp pending_block({:table, rows}) do
    text = Enum.join(rows, "\n")
    %Block{type: :table, text: text, rows: rows, canonical_text: text, complete?: true}
  end

  defp finalize_pending(blocks, %{in_code?: true, code_lines: code_lines, code_lang: lang}) do
    text = Enum.join(code_lines, "\n")

    blocks ++
      [%Block{type: :code_block, text: text, canonical_text: text, lang: lang, complete?: false}]
  end

  defp finalize_pending(blocks, state), do: flush_pending(blocks, state)

  defp heading_block(line) do
    {level, text} =
      cond do
        String.starts_with?(line, "### ") -> {3, String.trim_leading(line, "### ")}
        String.starts_with?(line, "## ") -> {2, String.trim_leading(line, "## ")}
        String.starts_with?(line, "# ") -> {1, String.trim_leading(line, "# ")}
        true -> {1, String.trim(line)}
      end

    %Block{
      type: :heading,
      level: level,
      text: text,
      canonical_text: line,
      complete?: true
    }
  end

  defp code_block(lines, lang) do
    text = Enum.join(lines, "\n")
    %Block{type: :code_block, text: text, canonical_text: text, lang: lang, complete?: true}
  end

  defp parse_code_lang(line) do
    line
    |> String.trim_leading("```")
    |> String.trim()
    |> case do
      "" -> nil
      lang -> lang
    end
  end

  defp heading?(line), do: Regex.match?(~r/^\#{1,3}\s+/, line)
  defp list_item?(line), do: Regex.match?(~r/^([-*]|\d+\.)\s+/, line)
  defp quote_line?(line), do: Regex.match?(~r/^>\s?/, line)

  defp table_row?(line) do
    trimmed = String.trim(line)
    # A table row must start and/or end with | as a cell delimiter.
    # Reject lines where | only appears as Discord spoiler tags (||text||).
    trimmed != "" and
      String.contains?(trimmed, "|") and
      not Regex.match?(~r/\A[^|]*\|\|[^|]*\|\|[^|]*\z/, trimmed) and
      (String.starts_with?(trimmed, "|") or String.ends_with?(trimmed, "|"))
  end

  defp tables_enabled?(profile) do
    get_in(profile, [:markdown, :tables]) != false
  end

  defp blank_paragraph?(%Block{type: :paragraph, text: text}), do: String.trim(text) == ""
  defp blank_paragraph?(_block), do: false

  defp state_to_buffer(state, partial_tail) do
    lines =
      cond do
        state.in_code? ->
          state.code_lines

        match?({_, _}, state.pending) ->
          pending_lines(state.pending)

        true ->
          []
      end

    parts =
      case partial_tail do
        "" -> lines
        tail -> lines ++ [tail]
      end

    Enum.join(parts, "\n")
  end

  defp pending_lines({_, lines}), do: lines

  defp new_message_prefix?(partial_tail, profile) do
    token = profile[:new_message_token] || ""
    partial_tail != "" and String.starts_with?(token, partial_tail)
  end

  defp normalize_new_message_tokens(text, profile) do
    token = profile[:new_message_token] || ""

    if token == "" do
      text
    else
      String.replace(text, token, "\n#{token}\n")
    end
  end
end
