defmodule Nex.Agent.RunControl do
  @moduledoc """
  In-memory owner run state for a workspace/session pair.

  RunControl owns only volatile execution state needed for busy/follow-up/stop
  coordination. It does not cache runtime snapshots or perform side effects.
  """

  use GenServer
  require Logger
  require Nex.Agent.ControlPlane.Gauge
  require Nex.Agent.ControlPlane.Log

  alias Nex.Agent.ControlPlane.Redactor

  @cancel_ref_ttl_ms 60 * 60 * 1000
  @tail_limit 4_000
  @gauge_tail_limit 1_000

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
          recent_runs: %{String.t() => map()},
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
    GenServer.call(
      server_name(opts),
      {:start_owner, normalize_workspace(workspace), session_key, normalize_attrs(attrs)}
    )
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
    GenServer.call(
      server_name(opts),
      {:owner_snapshot, normalize_workspace(workspace), session_key}
    )
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
    {:ok, %{owners: %{}, run_index: %{}, recent_runs: %{}, cancelled_refs: %{}}}
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

        observe_run("run.owner.started", run, %{
          "status" => Atom.to_string(run.status),
          "phase" => Atom.to_string(run.current_phase)
        })

        refresh_owner_gauge(state, run.workspace)

        {:reply, {:ok, run}, state}
    end
  end

  def handle_call({:finish_owner, run_id, _result}, _from, state) do
    case pop_current_run(state, run_id) do
      {:ok, run, state} ->
        state = state |> remember_recent_run(run) |> prune_state()

        observe_run("run.owner.finished", run, %{
          "status" => "finished",
          "phase" => Atom.to_string(run.current_phase)
        })

        refresh_owner_gauge(state, run.workspace)
        {:reply, :ok, state}

      :error ->
        observe_stale_result(state, run_id, "finish")
        {:reply, {:error, :stale}, prune_state(state)}
    end
  end

  def handle_call({:fail_owner, run_id, reason}, _from, state) do
    case pop_current_run(state, run_id) do
      {:ok, run, state} ->
        state = state |> remember_recent_run(run) |> prune_state()

        observe_run("run.owner.failed", run, %{
          "status" => "failed",
          "phase" => Atom.to_string(run.current_phase),
          "reason_type" => reason_type(reason),
          "summary" => error_summary(reason)
        })

        refresh_owner_gauge(state, run.workspace)
        {:reply, :ok, state}

      :error ->
        observe_stale_result(state, run_id, "fail")
        {:reply, {:error, :stale}, prune_state(state)}
    end
  end

  def handle_call({:cancel_owner, workspace, session_key, reason}, _from, state) do
    key = {workspace, session_key}

    case Map.get(state.owners, key) do
      %Run{} = run ->
        state =
          state
          |> delete_owner(key, run.id)
          |> remember_recent_run(run)
          |> remember_cancelled_ref(run.cancel_ref)
          |> prune_state()

        observe_run("run.owner.cancelled", run, %{
          "status" => "cancelled",
          "phase" => Atom.to_string(run.current_phase),
          "reason_type" => reason_type(reason)
        })

        refresh_owner_gauge(state, run.workspace)

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
        %{
          run
          | updated_at_ms: now,
            current_phase: :tool,
            current_tool: tool_name,
            latest_tool_output_tail: tail_text(output)
        }
      end)

    reply_with_state(update_reply, "tool_output")
  end

  def handle_call({:append_assistant_partial, run_id, text}, _from, state) do
    now = now_ms()

    update_reply =
      update_current_run(state, run_id, fn run ->
        %{
          run
          | updated_at_ms: now,
            current_phase: :llm,
            latest_assistant_partial: append_tail(run.latest_assistant_partial, text)
        }
      end)

    reply_with_state(update_reply, "assistant_partial")
  end

  def handle_call({:set_phase, run_id, phase}, _from, state) do
    now = now_ms()

    update_reply =
      update_current_run(state, run_id, fn run ->
        %{run | updated_at_ms: now, current_phase: phase}
      end)

    reply_with_state(update_reply, "phase")
  end

  def handle_call({:set_queued_count, run_id, count}, _from, state) do
    now = now_ms()

    update_reply =
      update_current_run(state, run_id, fn run ->
        %{run | updated_at_ms: now, queued_count: count}
      end)

    reply_with_state(update_reply, "queue")
  end

  def handle_call({:cancelled?, cancel_ref}, _from, state) do
    {:reply, Map.has_key?(state.cancelled_refs, cancel_ref), prune_state(state)}
  end

  defp reply_with_state({:ok, run, state}, update_type) do
    observe_run("run.owner.updated", run, run_update_attrs(run, update_type))
    state = prune_state(state)
    refresh_owner_gauge(state, run.workspace)
    {:reply, :ok, state}
  end

  defp reply_with_state({:error, run_id, state}, update_type) do
    observe_stale_result(state, run_id, update_type)
    {:reply, {:error, :stale}, prune_state(state)}
  end

  defp update_current_run(state, run_id, fun) do
    with {:ok, key} <- fetch_run_key(state, run_id),
         %Run{} = run <- Map.get(state.owners, key) do
      updated = fun.(run)
      {:ok, updated, put_owner(state, key, updated)}
    else
      _ -> {:error, run_id, state}
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

  defp remember_recent_run(state, %Run{} = run) do
    put_in(state.recent_runs[run.id], %{
      workspace: run.workspace,
      session_key: run.session_key,
      channel: run.channel,
      chat_id: run.chat_id,
      removed_at_ms: now_ms()
    })
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

    recent_runs =
      Enum.reduce(state.recent_runs, %{}, fn {run_id, meta}, acc ->
        if Map.get(meta, :removed_at_ms, 0) >= cutoff do
          Map.put(acc, run_id, meta)
        else
          acc
        end
      end)

    %{state | cancelled_refs: cancelled_refs, recent_runs: recent_runs}
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

  defp refresh_owner_gauge(state, workspace) do
    owners =
      state.owners
      |> Map.values()
      |> Enum.filter(&(&1.workspace == workspace))
      |> Enum.sort_by(& &1.started_at_ms)
      |> Enum.map(&owner_gauge_entry/1)

    _ =
      Nex.Agent.ControlPlane.Gauge.set(
        "run.owner.current",
        %{"owners" => owners},
        %{"source" => "run_control"},
        workspace: workspace
      )

    :ok
  rescue
    e ->
      Logger.warning("[RunControl] run.owner.current gauge failed: #{Exception.message(e)}")
      :ok
  end

  defp owner_gauge_entry(%Run{} = run) do
    %{
      "run_id" => run.id,
      "session_key" => run.session_key,
      "channel" => run.channel,
      "chat_id" => run.chat_id,
      "status" => Atom.to_string(run.status),
      "phase" => Atom.to_string(run.current_phase),
      "current_tool" => run.current_tool,
      "elapsed_ms" => max(now_ms() - run.started_at_ms, 0),
      "queued_count" => run.queued_count,
      "latest_assistant_partial_tail" => gauge_tail(run.latest_assistant_partial),
      "latest_tool_output_tail" => gauge_tail(run.latest_tool_output_tail),
      "updated_at" => ms_to_iso8601(run.updated_at_ms)
    }
    |> Redactor.redact()
  end

  defp gauge_tail(text) when is_binary(text) do
    text =
      if String.length(text) > @gauge_tail_limit do
        String.slice(text, -@gauge_tail_limit, @gauge_tail_limit)
      else
        text
      end

    Redactor.redact(text)
  end

  defp gauge_tail(_text), do: ""

  defp observe_run(tag, %Run{} = run, attrs) do
    attrs =
      attrs
      |> Map.merge(%{
        "elapsed_ms" => max(now_ms() - run.started_at_ms, 0),
        "queued_count" => run.queued_count,
        "current_tool" => run.current_tool
      })
      |> compact_attrs()

    opts = [
      workspace: run.workspace,
      run_id: run.id,
      session_key: run.session_key,
      channel: run.channel,
      chat_id: run.chat_id
    ]

    _ =
      case tag do
        "run.owner.failed" -> Nex.Agent.ControlPlane.Log.error(tag, attrs, opts)
        "run.owner.cancelled" -> Nex.Agent.ControlPlane.Log.warning(tag, attrs, opts)
        _ -> Nex.Agent.ControlPlane.Log.info(tag, attrs, opts)
      end

    :ok
  rescue
    e ->
      Logger.warning("[RunControl] #{tag} observation failed: #{Exception.message(e)}")
      :ok
  end

  defp observe_stale_result(state, run_id, operation) do
    meta = Map.get(state.recent_runs, run_id, %{})

    opts =
      []
      |> put_log_opt(:workspace, Map.get(meta, :workspace))
      |> put_log_opt(:run_id, run_id)
      |> put_log_opt(:session_key, Map.get(meta, :session_key))
      |> put_log_opt(:channel, Map.get(meta, :channel))
      |> put_log_opt(:chat_id, Map.get(meta, :chat_id))

    _ =
      Nex.Agent.ControlPlane.Log.warning(
        "run.owner.stale_result",
        %{"operation" => operation, "reason_type" => "stale_result"},
        opts
      )

    :ok
  rescue
    e ->
      Logger.warning(
        "[RunControl] run.owner.stale_result observation failed: #{Exception.message(e)}"
      )

      :ok
  end

  defp run_update_attrs(%Run{} = run, update_type) do
    %{
      "update_type" => update_type,
      "status" => Atom.to_string(run.status),
      "phase" => Atom.to_string(run.current_phase),
      "current_tool" => run.current_tool,
      "queued_count" => run.queued_count
    }
    |> compact_attrs()
  end

  defp error_summary(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 1000)
    |> String.slice(0, 1000)
  end

  defp reason_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_type(reason) when is_binary(reason), do: String.slice(reason, 0, 120)
  defp reason_type({type, _detail}) when is_atom(type), do: Atom.to_string(type)
  defp reason_type(%{__struct__: struct}), do: inspect(struct)
  defp reason_type(_reason), do: "error"

  defp compact_attrs(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp put_log_opt(opts, _key, nil), do: opts
  defp put_log_opt(opts, _key, ""), do: opts
  defp put_log_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ms_to_iso8601(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  rescue
    _e -> Nex.Agent.ControlPlane.Store.timestamp()
  end

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
