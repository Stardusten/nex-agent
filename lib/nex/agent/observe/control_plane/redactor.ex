defmodule Nex.Agent.Observe.ControlPlane.Redactor do
  @moduledoc false

  @sensitive_keys ~w(api_key authorization token access_token refresh_token secret password cookie)
  @redacted "[REDACTED]"

  @spec redact(term()) :: term()
  def redact(%_{} = value) do
    value
    |> Map.from_struct()
    |> redact()
  end

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(key) do
        {key, @redacted}
      else
        {key, redact(nested)}
      end
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  def redact(value) when is_binary(value), do: redact_text(value)
  def redact(value), do: value

  defp sensitive_key?(key) do
    normalized = key |> to_string() |> String.downcase()
    Enum.any?(@sensitive_keys, &String.contains?(normalized, &1))
  end

  defp redact_text(text) do
    text
    |> redact_authorization()
    |> redact_key_values()
  end

  defp redact_authorization(text) do
    Regex.replace(
      ~r/(authorization\s*[:=]\s*)(bearer\s+)?[^\s,\]}]+/i,
      text,
      fn _full, prefix, bearer -> prefix <> bearer <> @redacted end
    )
  end

  defp redact_key_values(text) do
    Regex.replace(
      ~r/((?:api_key|access_token|refresh_token|token|secret|password|cookie)\s*[:=]\s*)[^\s,\]}]+/i,
      text,
      fn _full, prefix -> prefix <> @redacted end
    )
  end
end
