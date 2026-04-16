defmodule Nex.Agent.Stream.Result do
  @moduledoc false

  @enforce_keys [:handled?, :run_id, :status]
  defstruct [
    :handled?,
    :run_id,
    :status,
    :final_content,
    :error,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          handled?: boolean(),
          run_id: String.t(),
          status: :ok | :error,
          final_content: String.t() | nil,
          error: term() | nil,
          metadata: map()
        }

  @spec ok(String.t(), String.t() | nil, map()) :: t()
  def ok(run_id, final_content, metadata \\ %{}) do
    %__MODULE__{
      handled?: true,
      run_id: run_id,
      status: :ok,
      final_content: final_content,
      metadata: metadata
    }
  end

  @spec error(String.t(), term(), String.t() | nil, map()) :: t()
  def error(run_id, reason, final_content \\ nil, metadata \\ %{}) do
    %__MODULE__{
      handled?: true,
      run_id: run_id,
      status: :error,
      final_content: final_content,
      error: reason,
      metadata: metadata
    }
  end

  @spec message_sent?(t()) :: boolean()
  def message_sent?(%__MODULE__{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "message_sent") == true or Map.get(metadata, :message_sent) == true
  end

  def message_sent?(_result), do: false
end

defimpl String.Chars, for: Nex.Agent.Stream.Result do
  def to_string(%Nex.Agent.Stream.Result{final_content: content}) when is_binary(content),
    do: content

  def to_string(%Nex.Agent.Stream.Result{error: error, status: :error}), do: inspect(error)
  def to_string(_result), do: ""
end
