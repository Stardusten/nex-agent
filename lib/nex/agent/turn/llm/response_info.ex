defmodule Nex.Agent.Turn.LLM.ResponseInfo do
  @moduledoc false

  @spec finish_reason(map()) :: term()
  def finish_reason(response) when is_map(response) do
    Map.get(response, :finish_reason) || Map.get(response, "finish_reason")
  end

  @spec usage(map()) :: term()
  def usage(response) when is_map(response) do
    Map.get(response, :usage) || Map.get(response, "usage")
  end

  @spec status(map()) :: term()
  def status(response) when is_map(response) do
    Map.get(response, :status) || Map.get(response, "status")
  end

  @spec incomplete_reason(map()) :: String.t() | nil
  def incomplete_reason(response) when is_map(response) do
    metadata = metadata(response)

    Map.get(response, :incomplete_reason) ||
      Map.get(response, "incomplete_reason") ||
      get_in(response, [:incomplete_details, :reason]) ||
      get_in(response, ["incomplete_details", "reason"]) ||
      get_in(metadata, [:incomplete_details, :reason]) ||
      get_in(metadata, ["incomplete_details", "reason"]) ||
      Map.get(metadata, :incomplete_reason) ||
      Map.get(metadata, "incomplete_reason") ||
      fallback_incomplete_reason(response, metadata)
  end

  def incomplete_reason(_response), do: nil

  @spec metadata(map()) :: map()
  def metadata(response) when is_map(response) do
    case Map.get(response, :response_metadata) || Map.get(response, "response_metadata") do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  def metadata(_response), do: %{}

  defp fallback_incomplete_reason(response, metadata) do
    if finish_reason(response) in ["incomplete", :incomplete] and has_status?(metadata) do
      "stream_ended_without_terminal_event"
    end
  end

  defp has_status?(metadata) when is_map(metadata) do
    not is_nil(Map.get(metadata, :status) || Map.get(metadata, "status"))
  end
end
