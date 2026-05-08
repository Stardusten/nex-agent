defmodule Nex.Agent.Runtime.PluginJobRunner do
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

  @spec enqueue_hook_job(String.t() | nil, String.t(), map()) :: :ok
  def enqueue_hook_job(plugin_id, job_id, ctx) when is_binary(job_id) and is_map(ctx) do
    entry = plugin_job(ctx, plugin_id, job_id)
    GenServer.cast(__MODULE__, {:enqueue, build_job(entry, "conversation.turn.finished", ctx)})
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:enqueue, nil}, state), do: {:noreply, state}

  def handle_cast({:enqueue, job}, state) do
    state =
      %{
        state
        | order: :queue.in(job.id, state.order),
          pending: Map.put(state.pending, job.id, job)
      }

    {:noreply, maybe_start_next(state)}
  end

  @impl true
  def handle_info({:job_finished, job_id, result}, state) do
    log_job_result(state.current, result)
    {:noreply, maybe_start_next(%{state | current: nil, pending: Map.delete(state.pending, job_id)})}
  end

  defp maybe_start_next(%__MODULE__{current: nil} = state) do
    case dequeue_next_job(state.order, state.pending) do
      {:ok, job, order} ->
        parent = self()

        {:ok, _pid} =
          Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
            send(parent, {:job_finished, job.id, run_job(job)})
          end)

        emit_job_observation("plugin.job.started", job, %{"event" => job.event})
        %{state | current: job, order: order}

      :empty ->
        state
    end
  end

  defp maybe_start_next(state), do: state

  defp dequeue_next_job(order, pending) do
    case :queue.out(order) do
      {{:value, id}, rest} ->
        case Map.get(pending, id) do
          nil -> dequeue_next_job(rest, pending)
          job -> {:ok, job, rest}
        end

      {:empty, _} ->
        :empty
    end
  end

  defp run_job(%{action: %{"type" => "tool_call"} = action, ctx: ctx} = job) do
    args = Template.render(Map.get(action, "args", %{}), ctx)

    ToolRegistry.execute(
      Map.fetch!(action, "tool"),
      args,
      ctx
      |> Map.put(:plugin_id, job.plugin_id)
      |> Map.put(:job_id, job.id)
      |> Map.put(:actor, %{"kind" => "system", "id" => "plugin-job"})
    )
  end

  defp run_job(%{action: %{"type" => "write_workspace_file"} = action, ctx: ctx}) do
    path = Template.render(Map.get(action, "path", ""), ctx)
    content = Template.render(Map.get(action, "content", ""), ctx)

    FileSystem.write_file(
      Path.expand(path, Map.get(ctx, :workspace) || File.cwd!()),
      content,
      ctx
      |> Map.put(:plugin_id, Map.get(ctx, :plugin_id))
      |> Map.put(:job_id, Map.get(ctx, :job_id))
      |> Map.put(:actor, %{"kind" => "system", "id" => "plugin-job"})
    )
    |> case do
      :ok -> {:ok, %{"status" => "written"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_job(_job), do: {:error, "Unsupported plugin job action"}

  defp plugin_jobs(%{runtime_snapshot: %{plugins: plugins}}), do: plugin_jobs(%{plugin_data: plugins})
  defp plugin_jobs(%{plugin_data: nil}), do: []
  defp plugin_jobs(%{plugin_data: plugins}) do
    contributions = Map.get(plugins, :contributions) || Map.get(plugins, "contributions") || %{}
    Map.get(contributions, :jobs) || Map.get(contributions, "jobs") || []
  end
  defp plugin_jobs(_ctx), do: []

  defp plugin_job(ctx, plugin_id, job_id) do
    plugin_jobs(ctx)
    |> Enum.find(fn
      %{"plugin_id" => ^plugin_id, "id" => ^job_id} -> true
      %{"id" => ^job_id} when is_nil(plugin_id) -> true
      _ -> false
    end)
  end

  defp build_job(%{"attrs" => %{} = attrs, "plugin_id" => plugin_id, "id" => contribution_id}, event, ctx) do
    id = "#{plugin_id}:#{contribution_id}:#{System.unique_integer([:positive])}"

    job = %{
      id: id,
      plugin_id: plugin_id,
      contribution_id: contribution_id,
      event: event,
      action: stringify_map(Map.get(attrs, "action", %{})),
      workspace: Map.get(ctx, :workspace),
      ctx:
        ctx
        |> Map.put(:plugin_id, plugin_id)
        |> Map.put(:job_id, id)
    }

    emit_job_observation("plugin.job.queued", job, %{"event" => event})
    job
  end

  defp build_job(_entry, _event, _ctx), do: nil

  defp log_job_result(nil, _result), do: :ok

  defp log_job_result(job, {:ok, result}) do
    emit_job_observation("plugin.job.finished", job, %{
      "result_status" => "ok",
      "result_summary" => inspect(result, limit: 20, printable_limit: 300)
    })
  end

  defp log_job_result(job, {:error, reason}) do
    emit_job_observation("plugin.job.failed", job, %{
      "result_status" => "error",
      "error_summary" => inspect(reason, limit: 20, printable_limit: 300)
    })
  end

  defp emit_job_observation(tag, job, attrs) do
    Log.info(
      tag,
      Map.merge(
        %{
          "plugin_id" => job.plugin_id,
          "contribution_id" => job.contribution_id,
          "job_id" => job.id
        },
        attrs
      ),
      workspace: job.workspace,
      session_key: Map.get(job.ctx, :session_key)
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
