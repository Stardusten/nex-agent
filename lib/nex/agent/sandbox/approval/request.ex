defmodule Nex.Agent.Sandbox.Approval.Request do
  @moduledoc """
  A pending sandbox approval request.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          workspace: String.t(),
          session_key: String.t(),
          channel: String.t() | nil,
          chat_id: String.t() | nil,
          kind: :path | :command | :mcp | :network,
          operation: atom(),
          subject: String.t(),
          description: String.t(),
          grant_key: String.t(),
          grant_options: [map()],
          metadata: map(),
          authorized_actor: map() | nil,
          requested_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          from: GenServer.from() | nil
        }

  defstruct id: nil,
            workspace: nil,
            session_key: nil,
            channel: nil,
            chat_id: nil,
            kind: :command,
            operation: :execute,
            subject: "",
            description: "",
            grant_key: "",
            grant_options: [],
            metadata: %{},
            authorized_actor: nil,
            requested_at: nil,
            expires_at: nil,
            from: nil

  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attrs = attrs |> Map.new() |> stringify_keys()
    kind = normalize_kind(Map.get(attrs, "kind"))
    operation = normalize_operation(Map.get(attrs, "operation"))
    subject = normalized_string(Map.get(attrs, "subject"))
    workspace = attrs |> Map.get("workspace", ".") |> to_string() |> Path.expand()

    %__MODULE__{
      id: normalized_string(Map.get(attrs, "id")) || unique_id(),
      workspace: workspace,
      session_key: normalized_string(Map.get(attrs, "session_key")) || "default",
      channel: normalized_string(Map.get(attrs, "channel")),
      chat_id: normalized_string(Map.get(attrs, "chat_id")),
      kind: kind,
      operation: operation,
      subject: subject,
      description:
        normalized_string(Map.get(attrs, "description")) ||
          default_description(kind, operation, subject),
      grant_key:
        normalized_string(Map.get(attrs, "grant_key")) ||
          default_grant_key(kind, operation, subject),
      grant_options: normalize_grant_options(Map.get(attrs, "grant_options")),
      metadata: normalize_metadata(Map.get(attrs, "metadata")),
      authorized_actor: normalize_actor(Map.get(attrs, "authorized_actor")),
      requested_at: normalize_datetime(Map.get(attrs, "requested_at")) || DateTime.utc_now(),
      expires_at: normalize_datetime(Map.get(attrs, "expires_at")),
      from: Map.get(attrs, "from")
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp unique_id do
    "approval_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp normalize_kind(kind) when kind in [:path, :command, :mcp, :network], do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    case String.trim(kind) do
      "path" -> :path
      "command" -> :command
      "mcp" -> :mcp
      "network" -> :network
      _ -> :command
    end
  end

  defp normalize_kind(_kind), do: :command

  defp normalize_operation(operation) when is_atom(operation) and not is_nil(operation),
    do: operation

  defp normalize_operation(operation) when is_binary(operation) do
    operation
    |> String.trim()
    |> case do
      "" -> :execute
      "execute" -> :execute
      "read" -> :read
      "write" -> :write
      "list" -> :list
      "search" -> :search
      "remove" -> :remove
      "mkdir" -> :mkdir
      "stat" -> :stat
      "stream" -> :stream
      "connect" -> :connect
      _value -> :execute
    end
  end

  defp normalize_operation(_operation), do: :execute

  defp normalized_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalized_string(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalized_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalized_string(_value), do: nil

  defp default_description(kind, operation, subject) do
    "#{kind}:#{operation} #{subject}"
  end

  defp default_grant_key(kind, operation, subject) do
    digest = :crypto.hash(:sha256, subject) |> Base.encode16(case: :lower)
    "#{kind}:#{operation}:exact:#{digest}"
  end

  defp normalize_grant_options(options) when is_list(options) do
    options
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_keys/1)
  end

  defp normalize_grant_options(_options), do: []

  defp normalize_metadata(%{} = metadata), do: stringify_keys(metadata)
  defp normalize_metadata(_metadata), do: %{}

  defp normalize_actor(%{} = actor), do: stringify_keys(actor)
  defp normalize_actor(_actor), do: nil

  defp normalize_datetime(%DateTime{} = datetime), do: datetime

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp normalize_datetime(_value), do: nil
end
