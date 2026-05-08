defmodule Nex.Agent.Tasks.Runner do
  @moduledoc false

  use GenServer

  alias Nex.Agent.Capability.Tool.Registry, as: ToolRegistry
  alias Nex.Agent.Extension.Plugin.Template
  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Sandbox.FileSystem
  require Log

  defstruct current: nil, order: :queue.new(), pending: %{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue_hook_task(String.t() | nil, String.t(), map()) :: :ok
  def enqueue_hook_task(plugin_id, task_id, ctx) when is_binary(task_id) and is_map(ctx) do
    entry = plugin_task(ctx, plugin_id, task_id)
    GenServer.cast(__MODULE__, {:enqueue, build_run(entry, "conversation.turn.finished", ctx)})
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:enqueue, nil}, state), do: {:noreply, state}

  def handle_cast({:enqueue, run}, state) do
    state =
      %{
        state
        | order: :queue.in(run.id, state.order),
          pending: Map.put(state.pending, run.id, run)
      }

    {:noreply, maybe_start_next(state)}
  end

  @impl true
  def handle_info({:task_run_finished, run_id, result}, state) do
    log_run_result(state.current, result)

    {:noreply,
     maybe_start_next(%{state | current: nil, pending: Map.delete(state.pending, run_id)})}
  end

  defp maybe_start_next(%__MODULE__{current: nil} = state) do
    case dequeue_next_run(state.order, state.pending) do
      {:ok, run, order} ->
        parent = self()

        {:ok, _pid} =
          Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
            send(parent, {:task_run_finished, run.id, execute_run(run)})
          end)

        emit_run_observation("plugin.task.started", run, %{"event" => run.event})
        %{state | current: run, order: order}

      :empty ->
        state
    end
  end

  defp maybe_start_next(state), do: state

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
    args = Template.render(Map.get(action, "args", %{}), ctx)

    ToolRegistry.execute(
      Map.fetch!(action, "tool"),
      args,
      ctx
      |> Map.put(:plugin_id, run.plugin_id)
      |> Map.put(:task_run_id, run.id)
      |> Map.put(:actor, %{"kind" => "system", "id" => "plugin-task"})
    )
  end

  defp execute_run(%{action: %{"type" => "write_workspace_file"} = action, ctx: ctx}) do
    path = Template.render(Map.get(action, "path", ""), ctx)
    content = Template.render(Map.get(action, "content", ""), ctx)

    FileSystem.write_file(
      Path.expand(path, Map.get(ctx, :workspace) || File.cwd!()),
      content,
      ctx
      |> Map.put(:plugin_id, Map.get(ctx, :plugin_id))
      |> Map.put(:task_run_id, Map.get(ctx, :task_run_id))
      |> Map.put(:actor, %{"kind" => "system", "id" => "plugin-task"})
    )
    |> case do
      :ok -> {:ok, %{"status" => "written"}}
      {:error, reason} -> {:error, reason}
    end
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

    run = %{
      id: id,
      plugin_id: plugin_id,
      contribution_id: contribution_id,
      event: event,
      action: stringify_map(Map.get(attrs, "action", %{})),
      workspace: Map.get(ctx, :workspace),
      ctx:
        ctx
        |> Map.put(:plugin_id, plugin_id)
        |> Map.put(:task_run_id, id)
    }

    emit_run_observation("plugin.task.queued", run, %{"event" => event})
    run
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
      session_key: Map.get(run.ctx, :session_key)
    )
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_map(_), do: %{}
end
