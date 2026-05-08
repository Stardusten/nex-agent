defmodule Nex.Agent.Tasks.Runner do
  @moduledoc false

  use GenServer

  alias Nex.Agent.Capability.Tool.Registry, as: ToolRegistry
  alias Nex.Agent.Extension.Plugin.Template
  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Sandbox.FileSystem
  require Log

  defstruct current: nil,
            order: :queue.new(),
            pending: %{},
            debounce: %{}

  @type run :: %{
          id: String.t(),
          run_key: String.t(),
          plugin_id: String.t(),
          contribution_id: String.t(),
          event: String.t(),
          action: map(),
          workspace: String.t() | nil,
          ctx: map(),
          max_runs: pos_integer() | nil,
          debounce_key: String.t() | nil,
          debounce_ms: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue_hook_task(String.t() | nil, String.t(), map()) :: :ok
  def enqueue_hook_task(plugin_id, task_id, ctx) when is_binary(task_id) and is_map(ctx) do
    enqueue_task(plugin_id, task_id, "conversation.turn.finished", ctx)
  end

  @spec enqueue_task(String.t() | nil, String.t(), String.t(), map()) :: :ok
  def enqueue_task(plugin_id, task_id, event, ctx) when is_binary(task_id) and is_map(ctx) do
    entry = plugin_task(ctx, plugin_id, task_id)
    GenServer.cast(__MODULE__, {:enqueue, build_run(entry, event, ctx)})
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:enqueue, nil}, state), do: {:noreply, state}

  def handle_cast({:enqueue, run}, state) do
    {:noreply, state |> enqueue_run(run) |> maybe_start_next()}
  end

  @impl true
  def handle_info({:debounce_fire, key}, state) do
    case Map.pop(state.debounce, key) do
      {nil, _debounce} ->
        {:noreply, state}

      {%{run: run}, debounce} ->
        {:noreply,
         state
         |> Map.put(:debounce, debounce)
         |> enqueue_ready_run(run)
         |> maybe_start_next()}
    end
  end

  def handle_info({:task_run_finished, run_id, result}, state) do
    log_run_result(state.current, result)

    {:noreply,
     maybe_start_next(%{state | current: nil, pending: Map.delete(state.pending, run_id)})}
  end

  defp enqueue_run(state, %{debounce_key: key, debounce_ms: ms} = run)
       when is_binary(key) and key != "" and is_integer(ms) and ms > 0 do
    debounce_key = run.plugin_id <> ":" <> run.contribution_id <> ":" <> key

    state =
      case Map.get(state.debounce, debounce_key) do
        nil ->
          state

        %{ref: ref, run: previous} ->
          _ = Process.cancel_timer(ref)

          emit_run_observation("plugin.task.debounced", run, %{
            "event" => run.event,
            "reason" => "debounce_replaced",
            "previous_task_run_id" => previous.id
          })

          state
      end

    ref = Process.send_after(self(), {:debounce_fire, debounce_key}, ms)
    %{state | debounce: Map.put(state.debounce, debounce_key, %{ref: ref, run: run})}
  end

  defp enqueue_run(state, run), do: enqueue_ready_run(state, run)

  defp enqueue_ready_run(state, run) do
    if max_runs_reached?(state, run) do
      emit_run_observation("plugin.task.debounced", run, %{
        "event" => run.event,
        "reason" => "max_runs_reached"
      })

      state
    else
      emit_run_observation("plugin.task.queued", run, %{"event" => run.event})

      %{
        state
        | order: :queue.in(run.id, state.order),
          pending: Map.put(state.pending, run.id, run)
      }
    end
  end

  defp max_runs_reached?(state, %{max_runs: 1, run_key: run_key}) do
    running? = match?(%{run_key: ^run_key}, state.current)
    pending? = Enum.any?(state.pending, fn {_id, run} -> run.run_key == run_key end)
    debouncing? = Enum.any?(state.debounce, fn {_key, %{run: run}} -> run.run_key == run_key end)
    running? or pending? or debouncing?
  end

  defp max_runs_reached?(_state, _run), do: false

  defp maybe_start_next(%__MODULE__{current: nil} = state) do
    case dequeue_next_run(state.order, state.pending) do
      {:ok, run, order} ->
        state = %{state | current: run, order: order}

        case start_run_task(run) do
          {:ok, _pid} ->
            emit_run_observation("plugin.task.started", run, %{"event" => run.event})
            state

          {:error, reason} ->
            log_run_result(run, {:error, reason})
            maybe_start_next(%{state | current: nil, pending: Map.delete(state.pending, run.id)})
        end

      :empty ->
        state
    end
  end

  defp maybe_start_next(state), do: state

  defp start_run_task(run) do
    parent = self()

    Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
      send(parent, {:task_run_finished, run.id, execute_run(run)})
    end)
  end

  defp dequeue_next_run(order, pending) do
    case :queue.out(order) do
      {{:value, id}, rest} ->
        case Map.get(pending, id) do
          nil -> dequeue_next_run(rest, pending)
          run -> {:ok, run, rest}
        end

      {:empty, _} ->
        :empty
    end
  end

  defp execute_run(%{action: %{"type" => "tool_call"} = action, ctx: ctx} = run) do
    case normalize_string(Map.get(action, "tool")) do
      nil ->
        {:error, "Plugin task tool_call requires action.tool"}

      tool ->
        args = Template.render(Map.get(action, "args", %{}), ctx)

        ToolRegistry.execute(
          tool,
          args,
          ctx
          |> Map.put(:plugin_id, run.plugin_id)
          |> Map.put(:task_run_id, run.id)
          |> Map.put(:actor, %{"kind" => "system", "id" => "plugin-task"})
        )
    end
  end

  defp execute_run(%{action: %{"type" => "write_workspace_file"} = action, ctx: ctx} = run) do
    path = Template.render(Map.get(action, "path", ""), ctx)
    content = Template.render(Map.get(action, "content", ""), ctx)

    FileSystem.write_file(
      Path.expand(path, ctx_value(ctx, :workspace) || File.cwd!()),
      content,
      ctx
      |> Map.put(:plugin_id, run.plugin_id)
      |> Map.put(:task_run_id, run.id)
      |> Map.put(:actor, %{"kind" => "system", "id" => "plugin-task"})
    )
    |> case do
      :ok -> {:ok, %{"status" => "written"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_run(%{action: %{"type" => type}}) do
    {:error, "Unsupported plugin task action: #{type}"}
  end

  defp execute_run(_run), do: {:error, "Unsupported plugin task action"}

  defp plugin_tasks(%{runtime_snapshot: %{plugins: plugins}}),
    do: plugin_tasks(%{plugin_data: plugins})

  defp plugin_tasks(%{plugin_data: nil}), do: []

  defp plugin_tasks(%{plugin_data: plugins}) do
    contributions = Map.get(plugins, :contributions) || Map.get(plugins, "contributions") || %{}
    Map.get(contributions, :tasks) || Map.get(contributions, "tasks") || []
  end

  defp plugin_tasks(_ctx), do: []

  defp plugin_task(ctx, plugin_id, task_id) do
    plugin_tasks(ctx)
    |> Enum.find(fn
      %{"plugin_id" => ^plugin_id, "id" => ^task_id} -> true
      %{"id" => ^task_id} when is_nil(plugin_id) -> true
      _ -> false
    end)
  end

  defp build_run(
         %{"attrs" => %{} = attrs, "plugin_id" => plugin_id, "id" => contribution_id},
         event,
         ctx
       ) do
    id = "#{plugin_id}:#{contribution_id}:#{System.unique_integer([:positive])}"
    run_key = "#{plugin_id}:#{contribution_id}:#{event}"
    policy = stringify_map(Map.get(attrs, "policy", %{}))

    run_ctx =
      ctx
      |> Map.put(:plugin_id, plugin_id)
      |> Map.put(:task_run_id, id)

    %{
      id: id,
      run_key: run_key,
      plugin_id: plugin_id,
      contribution_id: contribution_id,
      event: event,
      action: stringify_map(Map.get(attrs, "action", %{})),
      workspace: ctx_value(ctx, :workspace),
      ctx: run_ctx,
      max_runs:
        normalize_positive_integer(Map.get(policy, "max_runs") || Map.get(policy, "maxRuns")),
      debounce_key:
        render_optional_string(
          Map.get(policy, "debounce_key") || Map.get(policy, "debounceKey"),
          run_ctx
        ),
      debounce_ms:
        normalize_non_negative_integer(
          Map.get(policy, "debounce_ms") || Map.get(policy, "debounceMs"),
          0
        )
    }
  end

  defp build_run(_entry, _event, _ctx), do: nil

  defp log_run_result(nil, _result), do: :ok

  defp log_run_result(run, {:ok, result}) do
    emit_run_observation("plugin.task.finished", run, %{
      "result_status" => "ok",
      "result_summary" => inspect(result, limit: 20, printable_limit: 300)
    })
  end

  defp log_run_result(run, {:error, reason}) do
    emit_run_observation("plugin.task.failed", run, %{
      "result_status" => "error",
      "error_summary" => inspect(reason, limit: 20, printable_limit: 300)
    })
  end

  defp emit_run_observation(tag, run, attrs) do
    Log.info(
      tag,
      Map.merge(
        %{
          "plugin_id" => run.plugin_id,
          "contribution_id" => run.contribution_id,
          "task_run_id" => run.id
        },
        attrs
      ),
      workspace: run.workspace,
      session_key: ctx_value(run.ctx, :session_key)
    )
  end

  defp render_optional_string(nil, _ctx), do: nil

  defp render_optional_string(value, ctx) do
    value
    |> Template.render(ctx)
    |> normalize_string()
  end

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_string(_value), do: nil

  defp normalize_positive_integer(value) do
    case normalize_non_negative_integer(value, nil) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp normalize_non_negative_integer(_value, default), do: default

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_map(_), do: %{}

  defp ctx_value(ctx, key) when is_map(ctx) do
    Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key))
  end

  defp ctx_value(_ctx, _key), do: nil
end
