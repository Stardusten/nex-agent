defmodule Nex.Agent.Turn.ContextWindow.Estimator do
  @moduledoc false

  @spec estimate(term()) :: non_neg_integer()
  def estimate(value), do: estimate_breakdown(value).total

  @spec estimate_breakdown(term()) :: map()
  def estimate_breakdown(value) do
    total = estimate_value(value, :text)

    %{
      total: total,
      text: total,
      tool_outputs: 0,
      tool_schemas: 0,
      media: 0,
      runtime_prompt: 0,
      method: "byte_heuristic_v1"
    }
  end

  @spec truncate_text(String.t(), pos_integer()) :: {String.t(), map()}
  def truncate_text(text, token_limit) when is_binary(text) and is_integer(token_limit) do
    original_tokens = estimate(text)

    if token_limit <= 0 or original_tokens <= token_limit do
      {text,
       %{
         truncated?: false,
         original_tokens_estimate: original_tokens,
         visible_tokens_estimate: original_tokens,
         token_limit: token_limit,
         method: "byte_heuristic_v1"
       }}
    else
      note =
        "\n... (truncated to #{token_limit} estimated tokens; original #{original_tokens} estimated tokens)"

      note_tokens = estimate(note)
      body_limit = max(token_limit - note_tokens, 1)
      body = take_within_token_limit(text, body_limit)
      visible = body <> note

      {visible,
       %{
         truncated?: true,
         original_tokens_estimate: original_tokens,
         visible_tokens_estimate: estimate(visible),
         token_limit: token_limit,
         method: "byte_heuristic_v1"
       }}
    end
  end

  def truncate_text(text, _token_limit) when is_binary(text) do
    {text,
     %{
       truncated?: false,
       original_tokens_estimate: estimate(text),
       visible_tokens_estimate: estimate(text),
       token_limit: nil,
       method: "byte_heuristic_v1"
     }}
  end

  defp estimate_value(value, class) when is_binary(value) do
    cond do
      data_url?(value) or base64_like?(value) ->
        div(byte_size(value) + 1, 2)

      cjk_like?(value) ->
        String.length(value)

      class in [:json, :tool_schema] ->
        div(byte_size(value) + 2, 3)

      true ->
        div(byte_size(value) + 3, 4)
    end
  end

  defp estimate_value(value, _class)
       when is_atom(value) or is_number(value) or is_boolean(value) do
    value |> to_string() |> estimate_value(:text)
  end

  defp estimate_value(nil, _class), do: 0

  defp estimate_value(value, class) when is_list(value) do
    Enum.reduce(value, 0, fn item, acc -> acc + estimate_value(item, class) end)
  end

  defp estimate_value(value, _class) when is_map(value) do
    class = classify_map(value)

    Enum.reduce(value, 0, fn {key, val}, acc ->
      acc + estimate_value(key, class) + estimate_value(val, class)
    end)
  end

  defp estimate_value(value, class), do: value |> inspect(limit: 20) |> estimate_value(class)

  defp take_within_token_limit(text, token_limit) do
    length = String.length(text)

    {best, _high} =
      do_take_within_token_limit(text, token_limit, 0, length, "")

    best
  end

  defp do_take_within_token_limit(_text, _token_limit, low, high, best) when low > high do
    {best, high}
  end

  defp do_take_within_token_limit(text, token_limit, low, high, best) do
    mid = div(low + high, 2)
    candidate = String.slice(text, 0, mid)

    if estimate(candidate) <= token_limit do
      do_take_within_token_limit(text, token_limit, mid + 1, high, candidate)
    else
      do_take_within_token_limit(text, token_limit, low, mid - 1, best)
    end
  end

  defp classify_map(map) do
    role = Map.get(map, "role") || Map.get(map, :role)

    cond do
      role == "tool" -> :json
      Map.has_key?(map, "parameters") or Map.has_key?(map, :parameters) -> :tool_schema
      true -> :text
    end
  end

  defp cjk_like?(value), do: Regex.match?(~r/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/u, value)

  defp data_url?(value), do: String.starts_with?(value, "data:")

  defp base64_like?(value) do
    byte_size(value) > 512 and Regex.match?(~r/^[A-Za-z0-9+\/=\s]+$/, value)
  end
end
