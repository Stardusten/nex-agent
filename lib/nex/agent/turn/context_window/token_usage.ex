defmodule Nex.Agent.Turn.ContextWindow.TokenUsage do
  @moduledoc false

  @enforce_keys [
    :input_tokens,
    :cached_input_tokens,
    :output_tokens,
    :reasoning_output_tokens,
    :total_tokens,
    :source
  ]
  defstruct [
    :input_tokens,
    :cached_input_tokens,
    :output_tokens,
    :reasoning_output_tokens,
    :total_tokens,
    :source,
    raw: nil,
    missing_fields: []
  ]

  @type source :: :provider | :estimate | :mixed

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          reasoning_output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          source: source(),
          raw: map() | nil,
          missing_fields: [String.t()]
        }

  @fields [
    {"input_tokens", :input_tokens},
    {"cached_input_tokens", :cached_input_tokens},
    {"output_tokens", :output_tokens},
    {"reasoning_output_tokens", :reasoning_output_tokens},
    {"total_tokens", :total_tokens}
  ]

  @spec normalize(term(), keyword()) :: t() | nil
  def normalize(usage, opts \\ [])
  def normalize(nil, _opts), do: nil
  def normalize(%__MODULE__{} = usage, _opts), do: usage

  def normalize(usage, opts) when is_map(usage) do
    estimates = Keyword.get(opts, :estimates, %{})
    raw = stringify_keys(usage)

    input = integer_value(raw, "input_tokens")

    cached =
      integer_value(raw, "cached_input_tokens") ||
        nested_integer(raw, ["input_tokens_details", "cached_tokens"])

    output = integer_value(raw, "output_tokens")

    reasoning =
      integer_value(raw, "reasoning_output_tokens") ||
        nested_integer(raw, ["output_tokens_details", "reasoning_tokens"])

    total = integer_value(raw, "total_tokens")

    values = %{
      input_tokens: input,
      cached_input_tokens: cached,
      output_tokens: output,
      reasoning_output_tokens: reasoning,
      total_tokens: total
    }

    missing =
      @fields
      |> Enum.filter(fn {_name, key} -> is_nil(Map.fetch!(values, key)) end)
      |> Enum.map(fn {name, _key} -> name end)

    filled = %{
      input_tokens: fill(values.input_tokens, estimates, :input_tokens),
      cached_input_tokens: fill(values.cached_input_tokens, estimates, :cached_input_tokens, 0),
      output_tokens: fill(values.output_tokens, estimates, :output_tokens),
      reasoning_output_tokens:
        fill(values.reasoning_output_tokens, estimates, :reasoning_output_tokens, 0),
      total_tokens:
        values.total_tokens ||
          estimated_total(values, estimates)
    }

    %__MODULE__{
      input_tokens: non_negative(filled.input_tokens),
      cached_input_tokens: non_negative(filled.cached_input_tokens),
      output_tokens: non_negative(filled.output_tokens),
      reasoning_output_tokens: non_negative(filled.reasoning_output_tokens),
      total_tokens: non_negative(filled.total_tokens),
      source: if(missing == [], do: :provider, else: :mixed),
      raw: raw,
      missing_fields: missing
    }
  end

  def normalize(_usage, _opts), do: nil

  @spec to_summary(t() | nil) :: map() | nil
  def to_summary(nil), do: nil

  def to_summary(%__MODULE__{} = usage) do
    %{
      "input_tokens" => usage.input_tokens,
      "cached_input_tokens" => usage.cached_input_tokens,
      "output_tokens" => usage.output_tokens,
      "reasoning_output_tokens" => usage.reasoning_output_tokens,
      "total_tokens" => usage.total_tokens,
      "source" => Atom.to_string(usage.source),
      "missing_fields" => usage.missing_fields
    }
  end

  defp estimated_total(values, estimates) do
    input = values.input_tokens || estimate(estimates, :input_tokens, 0)
    output = values.output_tokens || estimate(estimates, :output_tokens, 0)
    input + output
  end

  defp fill(nil, estimates, key), do: estimate(estimates, key, 0)
  defp fill(value, _estimates, _key), do: value
  defp fill(nil, estimates, key, default), do: estimate(estimates, key, default)
  defp fill(value, _estimates, _key, _default), do: value

  defp estimate(estimates, key, default) when is_map(estimates) do
    Map.get(estimates, key) || Map.get(estimates, Atom.to_string(key)) || default
  end

  defp estimate(_estimates, _key, default), do: default

  defp integer_value(map, key) do
    map
    |> Map.get(key)
    |> normalize_integer()
  end

  defp nested_integer(map, path) do
    map
    |> get_in(path)
    |> normalize_integer()
  end

  defp normalize_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_integer(value) when is_float(value) and value >= 0, do: trunc(value)

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: 0

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: to_string(key)
      value = if is_map(value), do: stringify_keys(value), else: value
      {key, value}
    end)
  end
end
