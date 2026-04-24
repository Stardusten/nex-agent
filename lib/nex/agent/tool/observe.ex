defmodule Nex.Agent.Tool.Observe do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.ControlPlane.Query
  alias Nex.Agent.Workspace

  @actions ~w(summary query tail metrics incident)
  @filter_keys ~w(tag level run_id session_key query since limit)

  def name, do: "observe"

  def description do
    "Query the ControlPlane observation store for recent runtime facts, failures, metrics, gauges, budget, or incident evidence."
  end

  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: @actions,
            description: "Observation query action to run"
          },
          tag: %{type: "string", description: "Optional exact observation tag filter"},
          level: %{type: "string", description: "Optional observation level filter"},
          run_id: %{type: "string", description: "Optional run id filter"},
          session_key: %{type: "string", description: "Optional session key filter"},
          query: %{type: "string", description: "Optional text search across observation JSON"},
          since: %{type: "string", description: "Optional ISO8601 lower timestamp bound"},
          limit: %{type: "integer", description: "Maximum observations to return"}
        },
        required: ["action"]
      }
    }
  end

  def execute(args, ctx) when is_map(args) and is_map(ctx) do
    if Map.has_key?(args, "path") or Map.has_key?(args, :path) do
      {:error, "observe does not accept file paths"}
    else
      action = Map.get(args, "action") || Map.get(args, :action) || "summary"
      workspace = workspace_from(ctx)
      opts = [workspace: workspace]
      filters = filters_from(args)

      case action do
        "summary" -> {:ok, Query.summary(opts)}
        "query" -> {:ok, %{"observations" => Query.query(filters, opts)}}
        "tail" -> {:ok, %{"observations" => Query.tail(Map.get(filters, "limit", 20), opts)}}
        "metrics" -> {:ok, Query.metrics(filters, opts)}
        "incident" -> {:ok, Query.incident(filters, opts)}
        other -> {:error, "unsupported observe action: #{other}"}
      end
    end
  end

  def execute(_args, _ctx), do: {:error, "invalid observe arguments"}

  defp workspace_from(ctx) do
    case Map.get(ctx, :workspace) || Map.get(ctx, "workspace") do
      workspace when is_binary(workspace) and workspace != "" -> workspace
      _ -> Workspace.root()
    end
  end

  defp filters_from(args) do
    args
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(@filter_keys)
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
