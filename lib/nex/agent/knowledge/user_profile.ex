defmodule Nex.Agent.Knowledge.UserProfile do
  @moduledoc false

  alias Nex.Agent.Runtime.Workspace

  @spec workspace_path(keyword()) :: String.t()
  def workspace_path(opts \\ []) do
    Workspace.root(opts)
  end

  @spec read(keyword()) :: String.t()
  def read(opts \\ []) do
    path = path(opts)

    if File.exists?(path) do
      File.read!(path)
    else
      ""
    end
  end

  @spec write(String.t(), keyword()) :: :ok
  def write(content, opts \\ []) do
    File.write!(path(opts), content)
    :ok
  end

  @spec path(keyword()) :: String.t()
  def path(opts \\ []) do
    Path.join(workspace_path(opts), "USER.md")
  end
end
