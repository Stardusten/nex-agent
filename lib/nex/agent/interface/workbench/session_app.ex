defmodule Nex.Agent.Interface.Workbench.SessionApp do
  @moduledoc false

  alias Nex.Agent.Conversation.Command.StatusView
  alias Nex.Agent.Observe.ControlPlane.{Log, Query}
  alias Nex.Agent.Runtime.Snapshot

  alias Nex.Agent.{
    Runtime.Config,
    Conversation.InboundWorker,
    Conversation.RunControl,
    Conversation.Session,
    Conversation.SessionManager
  }

  require Log

  @recent_message_limit 24
  @recent_observation_limit 30
  @preview_limit 220
  @tail_limit 800

  @spec overview(Snapshot.t()) :: map()
  def overview(%Snapshot{} = snapshot) do
    workspace = workspace(snapshot)
    config = config(snapshot)
    runs = owner_runs(workspace)
    sessions = sessions(workspace, runs)
    run_index = Map.new(runs, &{&1.session_key, &1})

    session_maps =
      sessions
      |> Enum.map(&session_summary(&1, Map.get(run_index, &1.key), config, %{}))
      |> Enum.sort(&summary_before?/2)

    %{
      "sessions" => session_maps,
      "summary" => %{
        "total" => length(session_maps),
        "running" => Enum.count(session_maps, &(&1["status"] == "running")),
        "idle" => Enum.count(session_maps, &(&1["status"] == "idle")),
        "with_model_override" =>
          Enum.count(session_maps, &(get_in(&1, ["model", "override_key"]) not in [nil, ""]))
      }
    }
  end

  @spec detail(String.t(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def detail(session_key, %Snapshot{} = snapshot) when is_binary(session_key) do
    workspace = workspace(snapshot)
    config = config(snapshot)

    case load_or_active_session(session_key, workspace) do
      {:ok, session, run} ->
        {:ok, %{"session" => session_detail(session, run, config, workspace)}}

      :error ->
        {:error, "session not found"}
    end
  end

  @spec stop(String.t(), Snapshot.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def stop(session_key, %Snapshot{} = snapshot, args \\ %{}) when is_binary(session_key) do
    workspace = workspace(snapshot)
    reason = Map.get(args, "reason") || "workbench_stop"

    result =
      cond do
        Process.whereis(InboundWorker) ->
          case InboundWorker.stop_session(workspace, session_key, reason) do
            {:ok, %{cancelled?: false} = payload} ->
              case stop_via_run_control(workspace, session_key, reason) do
                {:ok, %{cancelled?: true} = fallback} ->
                  {:ok, Map.put(fallback, :dropped_queued, Map.get(payload, :dropped_queued, 0))}

                _ ->
                  {:ok, payload}
              end

            other ->
              other
          end

        Process.whereis(RunControl) ->
          stop_via_run_control(workspace, session_key, reason)

        true ->
          {:ok, %{cancelled?: false, run_id: nil, count: 0, dropped_queued: 0}}
      end

    case result do
      {:ok, payload} ->
        observe_stop(workspace, session_key, reason, payload)
        {:ok, %{"result" => atom_key_map_to_json(payload)}}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  @spec set_model(String.t(), Snapshot.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def set_model(session_key, %Snapshot{} = snapshot, args) when is_binary(session_key) do
    workspace = workspace(snapshot)
    config = config(snapshot)
    model_ref = model_ref(args)

    cond do
      model_ref in [nil, ""] ->
        {:error, "model is required"}

      model_ref in ["reset", "default"] ->
        session =
          session_key
          |> editable_session(workspace)
          |> Session.clear_model_override()
          |> save_session(workspace)

        invalidate_agent_session(workspace, session_key)
        observe_model_updated(workspace, session_key, "reset", nil)

        {:ok,
         %{
           "session" =>
             session_detail(session, owner_run(workspace, session_key), config, workspace)
         }}

      true ->
        session = editable_session(session_key, workspace)

        case StatusView.resolve_model_ref(config, session, model_ref) do
          {:ok, entry} ->
            session =
              session
              |> Session.put_model_override(entry.key)
              |> save_session(workspace)

            invalidate_agent_session(workspace, session_key)
            observe_model_updated(workspace, session_key, "set", entry.key)

            {:ok,
             %{
               "session" =>
                 session_detail(session, owner_run(workspace, session_key), config, workspace)
             }}

          {:error, :unknown_model, entries} ->
            {:error,
             "unknown model: #{model_ref}; available: #{entries |> Enum.map(& &1.key) |> Enum.join(", ")}"}
        end
    end
  end

  defp sessions(workspace, runs) do
    disk_sessions =
      workspace
      |> session_paths()
      |> Enum.map(&Session.load_from_path/1)
      |> Enum.reject(&is_nil/1)

    disk_by_key = Map.new(disk_sessions, &{&1.key, &1})

    active_only =
      runs
      |> Enum.reject(&Map.has_key?(disk_by_key, &1.session_key))
      |> Enum.map(fn run ->
        run.session_key
        |> Session.new()
        |> Map.put(:created_at, ms_to_datetime(run.started_at_ms))
        |> Map.put(:updated_at, ms_to_datetime(run.updated_at_ms))
      end)

    disk_sessions ++ active_only
  end

  defp load_or_active_session(session_key, workspace) do
    session = load_session(session_key, workspace)
    run = owner_run(workspace, session_key)

    cond do
      session -> {:ok, session, run}
      run -> {:ok, active_session(run), run}
      true -> :error
    end
  end

  defp editable_session(session_key, workspace) do
    load_session(session_key, workspace) || active_session(owner_run(workspace, session_key)) ||
      Session.new(session_key)
  end

  defp active_session(nil), do: nil

  defp active_session(%RunControl.Run{} = run) do
    run.session_key
    |> Session.new()
    |> Map.put(:created_at, ms_to_datetime(run.started_at_ms))
    |> Map.put(:updated_at, ms_to_datetime(run.updated_at_ms))
  end

  defp session_summary(%Session{} = session, run, config, warning_counts) do
    last_consolidated = session.last_consolidated || 0
    message_count = length(session.messages)
    {channel, chat_id} = parse_session_key(session.key)

    %{
      "key" => session.key,
      "channel" => channel,
      "chat_id" => chat_id,
      "status" => if(run, do: "running", else: "idle"),
      "created_at" => datetime_to_iso8601(session.created_at),
      "updated_at" => updated_at(session, run),
      "total_messages" => message_count,
      "last_consolidated" => last_consolidated,
      "unconsolidated_messages" => max(message_count - last_consolidated, 0),
      "last_message" => last_message_preview(session),
      "model" => model_view(config, session),
      "run" => run && run_view(run, :summary),
      "recent_warning_count" => Map.get(warning_counts, session.key, 0)
    }
  end

  defp session_detail(%Session{} = session, run, config, workspace) do
    observations = recent_observations(workspace, session.key)

    session
    |> session_summary(run, config, %{session.key => warning_count(observations)})
    |> Map.merge(%{
      "available_models" => model_entries(config, session),
      "messages" => recent_messages(session),
      "recent_observations" => observations,
      "run" => run && run_view(run, :detail)
    })
  end

  defp model_view(%Config{} = config, %Session{} = session) do
    resolution = StatusView.effective_model(config, session)
    runtime = resolution.runtime

    %{
      "current_key" => runtime && runtime.model_key,
      "model_id" => runtime && runtime.model_id,
      "provider_key" => runtime && runtime.provider_key,
      "source" => Atom.to_string(resolution.source),
      "override_key" => Session.model_override(session),
      "invalid_override_key" => resolution.invalid_override_key
    }
  end

  defp model_entries(%Config{} = config, %Session{} = session) do
    config
    |> StatusView.model_entries(session)
    |> Enum.map(fn entry ->
      %{
        "index" => entry.index,
        "key" => entry.key,
        "model_id" => entry.model_id,
        "provider_key" => entry.provider_key,
        "current" => entry.current?
      }
    end)
  end

  defp run_view(%RunControl.Run{} = run, mode) do
    %{
      "run_id" => run.id,
      "status" => Atom.to_string(run.status),
      "phase" => Atom.to_string(run.current_phase),
      "current_tool" => run.current_tool,
      "elapsed_ms" => max(System.system_time(:millisecond) - run.started_at_ms, 0),
      "queued_count" => run.queued_count,
      "updated_at" => ms_to_iso8601(run.updated_at_ms),
      "latest_assistant_partial_tail" =>
        truncate_text(run.latest_assistant_partial, tail_limit(mode)),
      "latest_tool_output_tail" => truncate_text(run.latest_tool_output_tail, tail_limit(mode))
    }
  end

  defp recent_messages(%Session{} = session) do
    session.messages
    |> Enum.take(-@recent_message_limit)
    |> Enum.map(fn message ->
      %{
        "role" => Map.get(message, "role"),
        "content" => truncate_text(Map.get(message, "content"), 700),
        "timestamp" => Map.get(message, "timestamp")
      }
    end)
  end

  defp recent_observations(workspace, session_key) do
    Query.query(%{"session_key" => session_key, "limit" => @recent_observation_limit},
      workspace: workspace
    )
  rescue
    _ -> []
  end

  defp warning_count(observations),
    do: Enum.count(observations, &(Map.get(&1, "level") in ["warning", "error", "critical"]))

  defp owner_runs(workspace) do
    if Process.whereis(RunControl), do: RunControl.owner_snapshots(workspace), else: []
  rescue
    _ -> []
  end

  defp owner_run(workspace, session_key) do
    if Process.whereis(RunControl) do
      case RunControl.owner_snapshot(workspace, session_key) do
        {:ok, run} -> run
        {:error, :idle} -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp load_session(session_key, workspace) do
    opts = [workspace: workspace]

    if Process.whereis(SessionManager) do
      SessionManager.get(session_key, opts) || Session.load(session_key, opts)
    else
      Session.load(session_key, opts)
    end
  end

  defp save_session(%Session{} = session, workspace) do
    opts = [workspace: workspace]

    if Process.whereis(SessionManager) do
      SessionManager.save_sync(session, opts)
    else
      :ok = Session.save(session, opts)
      session
    end
  end

  defp invalidate_agent_session(workspace, session_key) do
    if Process.whereis(InboundWorker) do
      InboundWorker.invalidate_agent_session(workspace, session_key)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp stop_via_run_control(workspace, session_key, reason) do
    with {:ok, result} <- RunControl.cancel_owner(workspace, session_key, reason) do
      {:ok,
       result
       |> Map.put_new(:count, if(Map.get(result, :cancelled?), do: 1, else: 0))
       |> Map.put_new(:dropped_queued, 0)}
    end
  end

  defp session_paths(workspace) do
    workspace
    |> session_dir()
    |> Path.join("*/messages.jsonl")
    |> Path.wildcard()
  end

  defp session_dir(workspace), do: Session.sessions_dir(workspace: workspace)

  defp workspace(%Snapshot{workspace: workspace}) when is_binary(workspace),
    do: Path.expand(workspace)

  defp workspace(_snapshot), do: Path.expand(Session.workspace_path())

  defp config(%Snapshot{config: %Config{} = config}), do: config
  defp config(_snapshot), do: %Config{}

  defp model_ref(args) when is_map(args) do
    args
    |> Map.get("model", Map.get(args, "model_key", Map.get(args, "ref")))
    |> normalize_string()
  end

  defp model_ref(_args), do: nil

  defp parse_session_key(session_key) do
    case String.split(to_string(session_key), ":", parts: 2) do
      [channel, chat_id] -> {channel, chat_id}
      [channel] -> {channel, ""}
    end
  end

  defp updated_at(%Session{} = session, nil), do: datetime_to_iso8601(session.updated_at)
  defp updated_at(_session, %RunControl.Run{} = run), do: ms_to_iso8601(run.updated_at_ms)

  defp last_message_preview(%Session{messages: messages}) do
    messages
    |> List.last()
    |> case do
      %{} = message -> truncate_text(Map.get(message, "content"), @preview_limit)
      _ -> nil
    end
  end

  defp summary_before?(left, right) do
    left_rank = if left["status"] == "running", do: 0, else: 1
    right_rank = if right["status"] == "running", do: 0, else: 1

    if left_rank == right_rank do
      (left["updated_at"] || "") >= (right["updated_at"] || "")
    else
      left_rank < right_rank
    end
  end

  defp atom_key_map_to_json(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp observe_stop(workspace, session_key, reason, payload) do
    {channel, chat_id} = parse_session_key(session_key)

    _ =
      Log.warning(
        "workbench.session.stop.requested",
        %{
          "reason_type" => reason_type(reason),
          "cancelled_count" => Map.get(payload, :count, 0),
          "dropped_queued" => Map.get(payload, :dropped_queued, 0)
        },
        workspace: workspace,
        run_id: Map.get(payload, :run_id),
        session_key: session_key,
        channel: channel,
        chat_id: chat_id
      )

    :ok
  rescue
    _ -> :ok
  end

  defp observe_model_updated(workspace, session_key, action, model_key) do
    {channel, chat_id} = parse_session_key(session_key)

    _ =
      Log.info(
        "workbench.session.model.updated",
        %{"action" => action, "model_key" => model_key},
        workspace: workspace,
        session_key: session_key,
        channel: channel,
        chat_id: chat_id
      )

    :ok
  rescue
    _ -> :ok
  end

  defp reason_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_type(reason) when is_binary(reason), do: String.slice(reason, 0, 120)

  defp reason_type(reason),
    do: reason |> inspect(limit: 20, printable_limit: 120) |> String.slice(0, 120)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason, limit: 20, printable_limit: 120)

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(_value), do: nil

  defp truncate_text(nil, _limit), do: nil
  defp truncate_text("", _limit), do: ""

  defp truncate_text(text, limit) when is_binary(text) do
    if String.length(text) <= limit do
      text
    else
      String.slice(text, 0, limit) <> "...[truncated]"
    end
  end

  defp truncate_text(text, limit),
    do: text |> inspect(limit: 20, printable_limit: limit) |> truncate_text(limit)

  defp tail_limit(:detail), do: @tail_limit
  defp tail_limit(:summary), do: @preview_limit

  defp datetime_to_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_to_iso8601(_value), do: nil

  defp ms_to_iso8601(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  rescue
    _ -> nil
  end

  defp ms_to_datetime(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp ms_to_datetime(_ms), do: DateTime.utc_now()
end
