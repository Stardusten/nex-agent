defmodule Nex.Agent.Sandbox.Approval.Grant do
  @moduledoc """
  Serializable approval grant helpers.
  """

  alias Nex.Agent.Sandbox.Approval.Request

  @type scope :: :session | :always

  @type t :: %{required(String.t()) => String.t()}

  @spec new(Request.t(), scope(), keyword()) :: t()
  def new(%Request{} = request, scope, opts \\ []) when scope in [:session, :always] do
    grant_key = Keyword.get(opts, :grant_key, request.grant_key)
    subject = Keyword.get(opts, :subject, request.subject)

    %{
      "kind" => Atom.to_string(request.kind),
      "operation" => Atom.to_string(request.operation),
      "subject" => subject,
      "grant_key" => grant_key,
      "scope" => Atom.to_string(scope),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @spec normalize(term()) :: t() | nil
  def normalize(%{} = grant) do
    grant = Map.new(grant, fn {key, value} -> {to_string(key), value} end)

    with kind when kind in ["path", "command", "mcp", "network"] <- string(grant["kind"]),
         operation when not is_nil(operation) <- string(grant["operation"]),
         subject when not is_nil(subject) <- string(grant["subject"]),
         grant_key when not is_nil(grant_key) <- string(grant["grant_key"]),
         scope when scope in ["session", "always"] <- string(grant["scope"]),
         created_at when not is_nil(created_at) <- string(grant["created_at"]) do
      %{
        "kind" => kind,
        "operation" => operation,
        "subject" => subject,
        "grant_key" => grant_key,
        "scope" => scope,
        "created_at" => created_at
      }
    else
      _ -> nil
    end
  end

  def normalize(_grant), do: nil

  defp string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp string(value) when is_integer(value), do: Integer.to_string(value)
  defp string(_value), do: nil
end
