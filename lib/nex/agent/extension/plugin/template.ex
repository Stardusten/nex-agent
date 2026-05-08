defmodule Nex.Agent.Extension.Plugin.Template do
  @moduledoc false

  @spec render(term(), map()) :: term()
  def render(value, ctx) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, render(nested, ctx)} end)
  end

  def render(value, ctx) when is_list(value) do
    Enum.map(value, &render(&1, ctx))
  end

  def render(value, ctx) when is_binary(value) do
    value
    |> String.replace("{{turn.prompt}}", to_string(Map.get(ctx, :turn_prompt) || ""))
    |> String.replace("{{session.key}}", to_string(Map.get(ctx, :session_key) || ""))
    |> String.replace("{{workspace.root}}", to_string(Map.get(ctx, :workspace) || ""))
    |> String.replace("{{channel}}", to_string(Map.get(ctx, :channel) || ""))
    |> String.replace("{{chat_id}}", to_string(Map.get(ctx, :chat_id) || ""))
  end

  def render(value, _ctx), do: value
end
