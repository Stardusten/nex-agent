defmodule Nex.Agent.Sandbox.FileSystem do
  @moduledoc """
  Authorized filesystem helpers for user/model controlled paths.

  Callers must authorize the path before reaching `File.*`. The public helpers
  accept either a raw path plus context or the canonical authorization info
  returned by `authorize/3`, which lets multi-step tools avoid repeated approval
  prompts for one logical path decision.
  """

  alias Nex.Agent.Sandbox.Security

  @type operation :: :read | :write | :list | :search | :remove | :mkdir | :stat | :stream
  @type path_info :: %{
          required(:input_path) => String.t(),
          required(:expanded_path) => String.t(),
          required(:canonical_path) => String.t(),
          required(:existing_ancestor) => String.t(),
          required(:existing_ancestor_realpath) => String.t(),
          required(:missing_suffix) => [String.t()],
          required(:target_exists?) => boolean()
        }

  @spec authorize(Path.t(), operation(), map() | keyword()) ::
          {:ok, path_info()} | {:ask, Nex.Agent.Sandbox.Approval.Request.t()} | {:error, term()}
  def authorize(path, operation, ctx) when is_binary(path) do
    Security.authorize_path(path, operation, ctx)
  end

  @spec read_file(Path.t() | path_info(), map() | keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file(path_or_info, ctx \\ %{})

  def read_file(%{canonical_path: path}, _ctx) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:file_error, path, reason}}
    end
  end

  def read_file(path, ctx) when is_binary(path) do
    with {:ok, info} <- authorize(path, :read, ctx) do
      read_file(info, ctx)
    end
  end

  @spec list_dir(Path.t() | path_info(), map() | keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_dir(path_or_info, ctx \\ %{})

  def list_dir(%{canonical_path: path}, _ctx) do
    case File.ls(path) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, {:file_error, path, reason}}
    end
  end

  def list_dir(path, ctx) when is_binary(path) do
    with {:ok, info} <- authorize(path, :list, ctx) do
      list_dir(info, ctx)
    end
  end

  @spec stat(Path.t() | path_info(), map() | keyword()) :: {:ok, File.Stat.t()} | {:error, term()}
  def stat(path_or_info, ctx \\ %{})

  def stat(%{canonical_path: path}, _ctx) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, {:file_error, path, reason}}
    end
  end

  def stat(path, ctx) when is_binary(path) do
    with {:ok, info} <- authorize(path, :stat, ctx) do
      stat(info, ctx)
    end
  end

  @spec regular?(Path.t() | path_info(), map() | keyword()) :: {:ok, boolean()} | {:error, term()}
  def regular?(path_or_info, ctx \\ %{})

  def regular?(%{canonical_path: path}, _ctx), do: {:ok, File.regular?(path)}

  def regular?(path, ctx) when is_binary(path) do
    with {:ok, info} <- authorize(path, :stat, ctx) do
      regular?(info, ctx)
    end
  end

  @spec directory?(Path.t() | path_info(), map() | keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def directory?(path_or_info, ctx \\ %{})

  def directory?(%{canonical_path: path}, _ctx), do: {:ok, File.dir?(path)}

  def directory?(path, ctx) when is_binary(path) do
    with {:ok, info} <- authorize(path, :stat, ctx) do
      directory?(info, ctx)
    end
  end

  @spec exists?(Path.t() | path_info(), map() | keyword()) :: {:ok, boolean()} | {:error, term()}
  def exists?(path_or_info, ctx \\ %{})

  def exists?(%{canonical_path: path}, _ctx), do: {:ok, File.exists?(path)}

  def exists?(path, ctx) when is_binary(path) do
    with {:ok, info} <- authorize(path, :stat, ctx) do
      exists?(info, ctx)
    end
  end

  @spec stream_file(Path.t() | path_info(), map() | keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream_file(path_or_info, ctx \\ %{})

  def stream_file(%{canonical_path: path}, _ctx) do
    if File.regular?(path) do
      {:ok, File.stream!(path, [], 2048)}
    else
      {:error, {:file_error, path, :not_regular}}
    end
  rescue
    e -> {:error, {:file_error, path, e}}
  end

  def stream_file(path, ctx) when is_binary(path) do
    with {:ok, info} <- authorize(path, :stream, ctx) do
      stream_file(info, ctx)
    end
  end

  @spec write_file(Path.t() | path_info(), iodata(), map() | keyword()) ::
          :ok | {:error, term()}
  def write_file(path_or_info, content, ctx \\ %{})

  def write_file(%{expanded_path: path}, content, _ctx) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      :ok
    else
      {:error, reason} -> {:error, {:file_error, path, reason}}
    end
  end

  def write_file(path, content, ctx) when is_binary(path) do
    with {:ok, info} <- authorize(path, :write, ctx) do
      write_file(info, content, ctx)
    end
  end

  @spec mkdir_p(Path.t() | path_info(), map() | keyword()) :: :ok | {:error, term()}
  def mkdir_p(path_or_info, ctx \\ %{})

  def mkdir_p(%{expanded_path: path}, _ctx) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file_error, path, reason}}
    end
  end

  def mkdir_p(path, ctx) when is_binary(path) do
    with {:ok, info} <- authorize(path, :mkdir, ctx) do
      mkdir_p(info, ctx)
    end
  end

  @spec remove(Path.t() | path_info(), map() | keyword()) :: :ok | {:error, term()}
  def remove(path_or_info, ctx \\ %{})

  def remove(%{expanded_path: path}, _ctx) do
    case File.rm(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file_error, path, reason}}
    end
  end

  def remove(path, ctx) when is_binary(path) do
    with {:ok, info} <- authorize(path, :remove, ctx) do
      remove(info, ctx)
    end
  end
end
