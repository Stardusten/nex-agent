defmodule Nex.Agent.SystemPrompt do
  @moduledoc """
  Thin wrapper over `ContextBuilder.build_system_prompt/1`.

  Kept only so existing supervised startup and cache invalidation call sites
  continue to work after the nanobot parity rewrite.
  """

  use Agent

  @workspace_path Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace")

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Build the full system prompt.
  """
  def build(opts \\ []) do
    Nex.Agent.ContextBuilder.build_system_prompt(
      Keyword.put_new(opts, :workspace, @workspace_path)
    )
  end

  @doc """
  Cache invalidation is a no-op under the parity implementation.
  """
  def invalidate_cache(_workspace \\ @workspace_path), do: :ok
end
