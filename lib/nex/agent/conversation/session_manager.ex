defmodule Nex.Agent.Conversation.SessionManager do
  @moduledoc """
  Session manager - get/create/load/save sessions.
  """

  use GenServer

  alias Nex.Agent.{Conversation.Session, Runtime.Workspace}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    {:ok, %{cache: %{}}}
  end

  @doc """
  Get existing session or create new one.
  """
  @spec get_or_create(String.t(), keyword()) :: Session.t()
  def get_or_create(key, opts \\ []) do
    GenServer.call(__MODULE__, {:get_or_create, key, opts})
  end

  @doc """
  Get session from cache (without loading from disk).
  """
  @spec get(String.t(), keyword()) :: Session.t() | nil
  def get(key, opts \\ []) do
    GenServer.call(__MODULE__, {:get, key, opts})
  end

  @doc """
  Save session to disk and update cache.
  """
  @spec save(Session.t(), keyword()) :: :ok
  def save(%Session{} = session, opts \\ []) do
    GenServer.cast(__MODULE__, {:save, session, opts})
  end

  @doc """
  Save session to disk and update cache synchronously.
  """
  @spec save_sync(Session.t(), keyword()) :: Session.t()
  def save_sync(%Session{} = session, opts \\ []) do
    GenServer.call(__MODULE__, {:save_sync, session, opts})
  end

  @doc """
  Invalidate cache for a session.
  """
  @spec invalidate(String.t(), keyword()) :: :ok
  def invalidate(key, opts \\ []) do
    GenServer.cast(__MODULE__, {:invalidate, key, opts})
  end

  @doc """
  List all sessions.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @impl true
  def handle_call({:get_or_create, key, opts}, _from, %{cache: cache} = state) do
    cache_key = cache_key(key, opts)

    session =
      case Map.get(cache, cache_key) do
        nil ->
          case Session.load(key, opts) do
            nil -> Session.new(key)
            s -> s
          end

        s ->
          s
      end

    {:reply, session, %{state | cache: Map.put(cache, cache_key, session)}}
  end

  def handle_call({:get, key, opts}, _from, %{cache: cache} = state) do
    {:reply, Map.get(cache, cache_key(key, opts)), state}
  end

  def handle_call({:list, opts}, _from, state) do
    sessions =
      Path.wildcard(Path.join([Session.sessions_dir(opts), "*", "messages.jsonl"]))
      |> Enum.map(fn path ->
        case File.read(path) do
          {:ok, content} ->
            [line | _] = String.split(content, "\n", trim: true)

            case Jason.decode(line) do
              {:ok, %{"_type" => "metadata", "key" => key, "updated_at" => updated_at}} ->
                %{key: key, updated_at: updated_at, path: path}

              _ ->
                nil
            end

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.updated_at, :desc)

    {:reply, sessions, state}
  end

  def handle_call({:save_sync, session, opts}, _from, %{cache: cache} = state) do
    cache_key = cache_key(session.key, opts)

    merged_session =
      cache
      |> Map.get(cache_key, Session.load(session.key, opts))
      |> merge_session(session)

    Session.save(merged_session, opts)
    {:reply, merged_session, %{state | cache: Map.put(cache, cache_key, merged_session)}}
  end

  @impl true
  def handle_cast({:save, session, opts}, %{cache: cache} = state) do
    cache_key = cache_key(session.key, opts)

    merged_session =
      cache
      |> Map.get(cache_key, Session.load(session.key, opts))
      |> merge_session(session)

    Session.save(merged_session, opts)
    {:noreply, %{state | cache: Map.put(cache, cache_key, merged_session)}}
  end

  def handle_cast({:invalidate, key, opts}, %{cache: cache} = state) do
    {:noreply, %{state | cache: Map.delete(cache, cache_key(key, opts))}}
  end

  defp merge_session(nil, %Session{} = incoming), do: incoming

  defp merge_session(%Session{} = existing, %Session{} = incoming) do
    messages =
      if length(incoming.messages) >= length(existing.messages) do
        incoming.messages
      else
        existing.messages
      end

    updated_at =
      case DateTime.compare(existing.updated_at, incoming.updated_at) do
        :gt -> existing.updated_at
        _ -> incoming.updated_at
      end

    # Deep-merge metadata so consolidation flags from either side are preserved.
    # Incoming values win for non-nil keys, but existing keys are kept when incoming is nil.
    merged_metadata =
      Map.merge(
        existing.metadata || %{},
        incoming.metadata || %{},
        fn _key, existing_val, incoming_val ->
          if is_nil(incoming_val), do: existing_val, else: incoming_val
        end
      )

    %Session{
      incoming
      | created_at: existing.created_at,
        updated_at: updated_at,
        metadata: merged_metadata,
        messages: messages
    }
  end

  defp cache_key(key, opts) do
    {Workspace.root(opts) |> Path.expand(), key}
  end
end
