defmodule Nex.Agent.RunControl do
  @moduledoc """
  In-memory owner run state for a workspace/session pair.

  RunControl owns only volatile execution state needed for busy/follow-up/stop
  coordination. It does not cache runtime snapshots or perform side effects.
  """

  use GenServer

  @cancel_ref_ttl_ms 60 * 60 * 1000
  @tail_limit 4_000

  defmodule Run do
    @moduledoc false

    @enforce_keys [
      :id,
      :workspace,
      :session_key,
      :channel,
      :chat_id,
      :status,
      :kind,
      :started_at_ms,
      :updated_at_ms,
      :current_phase,
      :latest_tool_output_tail,
      :latest_assistant_partial,
      :queued_count,
      :cancel_ref
    ]
    defstruct [
      :id,
      :workspace,
      :session_key,
      :channel,
      :chat_id,
      :status,
      :kind,
      :started_at_ms,
      :updated_at_ms,
      :current_phase,
      :current_tool,
      :latest_tool_output_tail,
      :latest_assistant_partial,
      :queued_count,
      :cancel_ref
    ]

    @type phase :: :starting | :llm | :tool | :streaming | :finalizing | :idle
    @type status :: :running | :cancelling

    @type t :: %__MODULE__{
            id: String.t(),
            workspace: String.t(),
            session_key: String.t(),
            channel: String.t(),
            chat_id: String.t(),
            status: status(),
            kind: :owner,
            started_at_ms: integer(),
            updated_at_ms: integer(),
            current_phase: phase(),
            current_tool: String.t() | nil,
            latest_tool_output_tail: String.t(),
            latest_assistant_partial: String.t(),
            queued_count: non_neg_integer(),
            cancel_ref: reference()
          }
  end

  @type start_attrs :: map() | keyword()
  @type owner_snapshot :: Run.t()

  @type state :: %{
          owners: %{{String.t(), String.t()} => Run.t()},
          run_index: %{String.t() => {String.t(), String.t()}},
          cancelled_refs: %{reference() => integer()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec start_owner(String.t(), String.t(), start_attrs()) ::
          {:ok, Run.t()} | {:error, :already_running}
  @spec start_owner(String.t(), String.t(), start_attrs(), keyword()) ::
          {:ok, Run.t()} | {:error, :already_running}
  def start_owner(workspace, session_key, attrs \\ %{}, opts \\ []) do
    GenServer.call(server_name(opts), {:start_owner, normalize_workspace(workspace), session_key, normalize_attrs(attrs)})
  end

  @spec finish_owner(String.t(), term()) :: :ok | {:error, :stale}
  @spec finish_owner(String.t(), term(), keyword()) :: :ok | {:error, :stale}
  def finish_owner(run_id, result, opts \\ []) do
    GenServer.call(server_name(opts), {:finish_owner, run_id, result})
  end

  @spec fail_owner(String.t(), term()) :: :ok | {:error, :stale}
  @spec fail_owner(String.t(), term(), keyword()) :: :ok | {:error, :stale}
  def fail_owner(run_id, reason, opts \\ []) do
    GenServer.call(server_name(opts), {:fail_owner, run_id, reason})
  end

  @spec cancel_owner(String.t(), String.t(), term()) ::
          {:ok, %{cancelled?: boolean(), run_id: String.t() | nil}}
  @spec cancel_owner(String.t(), String.t(), term(), keyword()) ::
          {:ok, %{cancelled?: boolean(), run_id: String.t() | nil}}
  def cancel_owner(workspace, session_key, reason, opts \\ []) do
    GenServer.call(
      server_name(opts),
      {:cancel_owner, normalize_workspace(workspace), session_key, reason}
    )
  end

  @spec owner_snapshot(String.t(), String.t()) :: {:ok, owner_snapshot()} | {:error, :idle}
  @spec owner_snapshot(String.t(), String.t(), keyword()) ::
          {:ok, owner_snapshot()} | {:error, :idle}
  def owner_snapshot(workspace, session_key, opts \\ []) do
    GenServer.call(server_name(opts), {:owner_snapshot, normalize_workspace(workspace), session_key})
  end

  @spec append_tool_output(String.t(), String.t(), iodata()) :: :ok | {:error, :stale}
  @spec append_tool_output(String.t(), String.t(), iodata(), keyword()) :: :ok | {:error, :stale}
  def append_tool_output(run_id, tool_name, output, opts \\ []) do
    GenServer.call(server_name(opts), {:append_tool_output, run_id, to_string(tool_name), output})
  end

  @spec append_assistant_partial(String.t(), iodata()) :: :ok | {:error, :stale}
  @spec append_assistant_partial(String.t(), iodata(), keyword()) :: :ok | {:error, :stale}
  def append_assistant_partial(run_id, text, opts \\ []) do
    GenServer.call(server_name(opts), {:append_assistant_partial, run_id, text})
  end

  @spec set_phase(String.t(), Run.phase()) :: :ok | {:error, :stale}
  @spec set_phase(String.t(), Run.phase(), keyword()) :: :ok | {:error, :stale}
  def set_phase(run_id, phase, opts \\ []) do
    GenServer.call(server_name(opts), {:set_phase, run_id, phase})
  end

  @spec set_queued_count(String.t(), non_neg_integer()) :: :ok | {:error, :stale}
  @spec set_queued_count(String.t(), non_neg_integer(), keyword()) :: :ok | {:error, :stale}
  def set_queued_count(run_id, count, opts \\ []) when is_integer(count) and count >= 0 do
    GenServer.call(server_name(opts), {:set_queued_count, run_id, count})
  end

  @spec cancelled?(reference()) :: boolean()
  @spec cancelled?(reference(), keyword()) :: boolean()
  def cancelled?(cancel_ref, opts \\ []) when is_reference(cancel_ref) do
    GenServer.call(server_name(opts), {:cancelled?, cancel_ref})
  end

  @impl true
  def init(:ok) do
    {:ok, %{owners: %{}, run_index: %{}, cancelled_refs: %{}}}
  end

  @impl true
  def handle_call({:start_owner, workspace, session_key, attrs}, _from, state) do
    key = {workspace, session_key}

    case Map.get(state.owners, key) do
      %Run{status: status} when status in [:running, :cancelling] ->
        {:reply, {:error, :already_running}, prune_state(state)}

      _ ->
        run = build_run(workspace, session_key, attrs)

        state =
          state
          |> put_owner(key, run)
          |> prune_state()

        {:reply, {:ok, run}, state}
    end
  end

  def handle_call({:finish_owner, run_id, _result}, _from, state) do
    case pop_current_run(state, run_id) do
      {:ok, _run, state} -> {:reply, :ok, prune_state(state)}
      :error -> {:reply, {:error, :stale}, prune_state(state)}
    end
  end

  def handle_call({:fail_owner, run_id, _reason}, _from, state) do
    case pop_current_run(state, run_id) do
      {:ok, _run, state} -> {:reply, :ok, prune_state(state)}
      :error -> {:reply, {:error, :stale}, prune_state(state)}
    end
  end

  def handle_call({:cancel_owner, workspace, session_key, _reason}, _from, state) do
    key = {workspace, session_key}

    case Map.get(state.owners, key) do
      %Run{} = run ->
        state =
          state
          |> delete_owner(key, run.id)
          |> remember_cancelled_ref(run.cancel_ref)
          |> prune_state()

        {:reply, {:ok, %{cancelled?: true, run_id: run.id}}, state}

      nil ->
        {:reply, {:ok, %{cancelled?: false, run_id: nil}}, prune_state(state)}
    end
  end

  def handle_call({:owner_snapshot, workspace, session_key}, _from, state) do
    reply =
      case Map.get(state.owners, {workspace, session_key}) do
        %Run{} = run -> {:ok, run}
        nil -> {:error, :idle}
      end

    {:reply, reply, prune_state(state)}
  end

  def handle_call({:append_tool_output, run_id, tool_name, output}, _from, state) do
    now = now_ms()

    update_reply =
      update_current_run(state, run_id, fn run ->
        %{run | updated_at_ms: now, current_phase: :tool, current_tool: tool_name,
          latest_tool_output_tail: tail_text(output)}
      end)

    reply_with_state(update_reply)
  end

  def handle_call({:append_assistant_partial, run_id, text}, _from, state) do
    now = now_ms()

    update_reply =
      update_current_run(state, run_id, fn run ->
        %{run | updated_at_ms: now, current_phase: :llm,
          latest_assistant_partial: append_tail(run.latest_assistant_partial, text)}
      end)

    reply_with_state(update_reply)
  end

  def handle_call({:set_phase, run_id, phase}, _from, state) do
    now = now_ms()

    update_reply =
      update_current_run(state, run_id, fn run ->
        %{run | updated_at_ms: now, current_phase: phase}
      end)

    reply_with_state(update_reply)
  end

  def handle_call({:set_queued_count, run_id, count}, _from, state) do
    now = now_ms()

    update_reply =
      update_current_run(state, run_id, fn run ->
        %{run | updated_at_ms: now, queued_count: count}
      end)

    reply_with_state(update_reply)
  end

  def handle_call({:cancelled?, cancel_ref}, _from, state) do
    {:reply, Map.has_key?(state.cancelled_refs, cancel_ref), prune_state(state)}
  end

  defp reply_with_state({:ok, state}) do
    {:reply, :ok, prune_state(state)}
  end

  defp reply_with_state({:error, state}) do
    {:reply, {:error, :stale}, prune_state(state)}
  end

  defp update_current_run(state, run_id, fun) do
    with {:ok, key} <- fetch_run_key(state, run_id),
         %Run{} = run <- Map.get(state.owners, key) do
      updated = fun.(run)
      {:ok, put_owner(state, key, updated)}
    else
      _ -> {:error, state}
    end
  end

  defp pop_current_run(state, run_id) do
    with {:ok, key} <- fetch_run_key(state, run_id),
         %Run{} = run <- Map.get(state.owners, key) do
      {:ok, run, delete_owner(state, key, run_id)}
    else
      _ -> :error
    end
  end

  defp fetch_run_key(state, run_id) do
    case Map.fetch(state.run_index, run_id) do
      {:ok, key} -> {:ok, key}
      :error -> :error
    end
  end

  defp put_owner(state, key, %Run{} = run) do
    %{
      state
      | owners: Map.put(state.owners, key, run),
        run_index: Map.put(state.run_index, run.id, key)
    }
  end

  defp delete_owner(state, key, run_id) do
    %{
      state
      | owners: Map.delete(state.owners, key),
        run_index: Map.delete(state.run_index, run_id)
    }
  end

  defp remember_cancelled_ref(state, cancel_ref) do
    put_in(state.cancelled_refs[cancel_ref], now_ms())
  end

  defp prune_state(state) do
    cutoff = now_ms() - @cancel_ref_ttl_ms

    cancelled_refs =
      Enum.reduce(state.cancelled_refs, %{}, fn {ref, cancelled_at_ms}, acc ->
        if cancelled_at_ms >= cutoff do
          Map.put(acc, ref, cancelled_at_ms)
        else
          acc
        end
      end)

    %{state | cancelled_refs: cancelled_refs}
  end

  defp build_run(workspace, session_key, attrs) do
    {channel, chat_id} = parse_session_key(session_key)
    now = now_ms()

    %Run{
      id: generate_run_id(),
      workspace: workspace,
      session_key: session_key,
      channel: get_attr(attrs, :channel, channel),
      chat_id: get_attr(attrs, :chat_id, chat_id),
      status: :running,
      kind: :owner,
      started_at_ms: now,
      updated_at_ms: now,
      current_phase: :starting,
      current_tool: get_attr(attrs, :current_tool),
      latest_tool_output_tail: tail_text(get_attr(attrs, :latest_tool_output_tail, "")),
      latest_assistant_partial: tail_text(get_attr(attrs, :latest_assistant_partial, "")),
      queued_count: normalize_count(get_attr(attrs, :queued_count, 0)),
      cancel_ref: make_ref()
    }
  end

  defp normalize_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_attrs(attrs) when is_list(attrs), do: Enum.into(attrs, %{})
  defp normalize_attrs(_attrs), do: %{}

  defp get_attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp normalize_count(count) when is_integer(count) and count >= 0, do: count
  defp normalize_count(_count), do: 0

  defp tail_text(text) do
    text
    |> IO.iodata_to_binary()
    |> truncate_tail()
  rescue
    _ -> ""
  end

  defp append_tail(existing, chunk) do
    truncate_tail(existing <> tail_text(chunk))
  end

  defp truncate_tail(text) when byte_size(text) <= @tail_limit, do: text
  defp truncate_tail(text), do: binary_part(text, byte_size(text) - @tail_limit, @tail_limit)

  defp parse_session_key(session_key) do
    case String.split(session_key, ":", parts: 2) do
      [channel, chat_id] -> {channel, chat_id}
      [channel] -> {channel, ""}
      _ -> {"unknown", ""}
    end
  end

  defp generate_run_id do
    "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp normalize_workspace(workspace), do: workspace |> to_string() |> Path.expand()
  defp now_ms, do: System.system_time(:millisecond)
  defp server_name(opts), do: Keyword.get(opts, :server, __MODULE__)
end
