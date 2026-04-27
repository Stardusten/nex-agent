defmodule Nex.Agent.Subagent do
  @moduledoc """
  Subagent - Background task execution with independent agent loop.

  Spawns background tasks that run an independent Runner loop with a profile
  selected prompt, model, context policy, tool surface, and result projection.
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Bus, Config, Session, SessionManager}
  alias Nex.Agent.Inbound.Envelope
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.SubAgent.Review
  alias Nex.Agent.Subagent.{Profile, Profiles}

  @max_subagent_iterations 15

  defstruct tasks: %{}

  @type task_entry :: %{
          id: String.t(),
          label: String.t(),
          profile: String.t(),
          description: String.t(),
          status: :running | :completed | :failed | :cancelled,
          return_mode: :inbound | :silent | nil,
          pid: pid() | nil,
          owner_run_id: String.t() | nil,
          session_key: String.t() | nil,
          workspace: String.t() | nil,
          started_at: integer(),
          completed_at: integer() | nil,
          result: String.t() | nil,
          error: term() | nil
        }

  @type t :: %__MODULE__{
          tasks: %{String.t() => task_entry()}
        }

  @max_completed_tasks 100

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: name)
  end

  @doc """
  Spawn a background subagent task.

  ## Options

  * `:label` - Short label for the task
  * `:profile` - Named subagent profile to use
  * `:context` - Optional task-specific context to include in the prompt
  * `:context_mode` - Context strategy override (`blank` or `parent_recent`)
  * `:return_mode` - Result projection override (`inbound` or `silent`)
  * `:model_role` - Runtime model role override
  * `:model_key` - Explicit config.model.models key override
  * `:session_key` - Session key of the parent (for cancel_by_session)
  * `:provider` - LLM provider atom
  * `:model` - LLM model string
  * `:api_key` - API key
  * `:base_url` - API base URL
  * `:channel` - Origin channel
  * `:chat_id` - Origin chat ID
  * `:workspace` - Parent workspace
  * `:cwd` - Parent working directory
  * `:project` - Parent project context
  """
  @spec spawn_task(String.t(), keyword()) :: {:ok, String.t()}
  def spawn_task(task_description, opts \\ []) do
    GenServer.call(__MODULE__, {:spawn, task_description, opts})
  end

  @doc """
  List all tasks.
  """
  @spec list() :: list(task_entry())
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Get task status by ID.
  """
  @spec status(String.t()) :: task_entry() | nil
  def status(task_id) do
    GenServer.call(__MODULE__, {:status, task_id})
  end

  @doc """
  Cancel a running task by ID.
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(task_id) do
    GenServer.call(__MODULE__, {:cancel, task_id})
  end

  @doc """
  Cancel all running tasks for a session key. Returns count cancelled.
  """
  @spec cancel_by_session(String.t(), keyword()) :: {:ok, non_neg_integer()}
  def cancel_by_session(session_key, opts \\ []) do
    GenServer.call(__MODULE__, {:cancel_by_session, session_key, opts})
  end

  @spec cancel_by_owner_run(String.t()) :: {:ok, non_neg_integer()}
  def cancel_by_owner_run(owner_run_id) when is_binary(owner_run_id) do
    GenServer.call(__MODULE__, {:cancel_by_owner_run, owner_run_id})
  end

  # GenServer callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:spawn, task_description, opts}, _from, state) do
    task_id = generate_id()
    label = opts[:label] || String.slice(task_description, 0, 30)
    profile = Profile.normalize_name(opts[:profile] || "general") || "general"
    session_key = opts[:session_key]
    owner_run_id = opts[:owner_run_id]
    server = self()

    {:ok, pid} =
      Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
        run_subagent_loop(server, task_id, task_description, label, opts)
      end)

    Process.monitor(pid)

    task = %{
      id: task_id,
      label: label,
      profile: profile,
      description: task_description,
      status: :running,
      return_mode: nil,
      pid: pid,
      owner_run_id: owner_run_id,
      session_key: session_key,
      workspace: opts[:workspace],
      started_at: System.system_time(:second),
      completed_at: nil,
      result: nil,
      error: nil
    }

    new_tasks = Map.put(state.tasks, task_id, task)
    {:reply, {:ok, task_id}, %{state | tasks: new_tasks}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.tasks), state}
  end

  @impl true
  def handle_call({:status, task_id}, _from, state) do
    {:reply, Map.get(state.tasks, task_id), state}
  end

  @impl true
  def handle_call({:cancel, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: :running, pid: pid} = task ->
        if pid, do: Process.exit(pid, :kill)
        updated = %{task | status: :cancelled, completed_at: System.system_time(:second)}
        {:reply, :ok, %{state | tasks: Map.put(state.tasks, task_id, updated)}}

      _task ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:cancel_by_session, session_key, opts}, _from, state) do
    workspace = Keyword.get(opts, :workspace)

    {cancelled, new_tasks} =
      Enum.reduce(state.tasks, {0, state.tasks}, fn {id, task}, {count, tasks} ->
        if task.session_key == session_key and workspace_match?(task.workspace, workspace) and
             task.status == :running do
          if task.pid, do: Process.exit(task.pid, :kill)
          updated = %{task | status: :cancelled, completed_at: System.system_time(:second)}
          {count + 1, Map.put(tasks, id, updated)}
        else
          {count, tasks}
        end
      end)

    {:reply, {:ok, cancelled}, %{state | tasks: new_tasks}}
  end

  @impl true
  def handle_call({:cancel_by_owner_run, owner_run_id}, _from, state) do
    {cancelled, new_tasks} =
      Enum.reduce(state.tasks, {0, state.tasks}, fn {id, task}, {count, tasks} ->
        if task.owner_run_id == owner_run_id and task.status == :running do
          if task.pid, do: Process.exit(task.pid, :kill)
          updated = %{task | status: :cancelled, completed_at: System.system_time(:second)}
          {count + 1, Map.put(tasks, id, updated)}
        else
          {count, tasks}
        end
      end)

    {:reply, {:ok, cancelled}, %{state | tasks: new_tasks}}
  end

  @impl true
  def handle_info({:task_complete, task_id, result, return_mode}, state) do
    state = update_task(state, task_id, :completed, result: result, return_mode: return_mode)
    {:noreply, state}
  end

  @impl true
  def handle_info({:task_failed, task_id, reason, return_mode}, state) do
    state = update_task(state, task_id, :failed, error: reason, return_mode: return_mode)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case find_task_by_pid(state, pid) do
      nil ->
        {:noreply, state}

      {task_id, task} when task.status == :running and reason != :normal ->
        Logger.warning("[Subagent] Task #{task_id} exited: #{inspect(reason)}")
        state = update_task(state, task_id, :failed, error: inspect(reason))
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Subagent loop (runs in spawned process) ---

  defp run_subagent_loop(server, task_id, task_description, label, opts) do
    start_time = System.monotonic_time(:millisecond)

    channel = Keyword.get(opts, :channel)
    chat_id = Keyword.get(opts, :chat_id)
    workspace = Keyword.get(opts, :workspace)
    cwd = Keyword.get(opts, :cwd)
    project = Keyword.get(opts, :project)
    session_key = Keyword.get(opts, :session_key)
    runtime_snapshot = Keyword.get(opts, :runtime_snapshot)
    config = Keyword.get(opts, :config) || runtime_config(runtime_snapshot)
    profile = resolve_profile(opts, config, runtime_snapshot, workspace)
    model_runtime = resolve_model_runtime(profile, config)

    provider =
      model_runtime_value(model_runtime, :provider) || Keyword.get(opts, :provider, :anthropic)

    model =
      model_runtime_value(model_runtime, :model_id) ||
        Keyword.get(opts, :model, Nex.Agent.LLM.ProviderProfile.default_model(provider))

    api_key = model_runtime_value(model_runtime, :api_key) || Keyword.get(opts, :api_key)
    base_url = model_runtime_value(model_runtime, :base_url) || Keyword.get(opts, :base_url)

    provider_options =
      (model_runtime_value(model_runtime, :provider_options) ||
         Keyword.get(opts, :provider_options, []))
      |> Keyword.merge(profile.provider_options || [])

    # Determine SubAgent module from label (if it contains module info)
    subagent_module = Keyword.get(opts, :subagent_module, Nex.Agent.Subagent)

    session = Session.new("subagent:#{task_id}")

    runner_opts =
      [
        provider: provider,
        model: model,
        api_key: api_key,
        base_url: base_url,
        model_runtime: model_runtime,
        provider_options: provider_options,
        max_iterations:
          Keyword.get(opts, :max_iterations) || profile.max_iterations || @max_subagent_iterations,
        channel: "system",
        chat_id: task_id,
        session_key: "subagent:#{task_id}",
        cancel_ref: Keyword.get(opts, :cancel_ref),
        workspace: workspace,
        cwd: cwd,
        project: project,
        runtime_snapshot: runtime_snapshot,
        tools_filter: profile.tools_filter,
        tool_allowlist: profile.tool_allowlist,
        skip_consolidation: true,
        metadata: %{
          "_subagent" => true,
          "subagent_profile" => profile.name,
          "parent_session_key" => session_key,
          "subagent_task_id" => task_id,
          "subagent_label" => label
        }
      ]
      |> maybe_put_opt(:llm_stream_client, Keyword.get(opts, :llm_stream_client))
      |> maybe_put_opt(:req_llm_stream_text_fun, Keyword.get(opts, :req_llm_stream_text_fun))
      |> maybe_put_opt(:llm_call_fun, Keyword.get(opts, :llm_call_fun))

    prompt =
      build_profile_prompt(
        profile,
        task_id,
        task_description,
        label,
        opts,
        workspace,
        session_key
      )

    try do
      case Nex.Agent.Runner.run(session, prompt, runner_opts) do
        {:ok, result, final_session} ->
          duration = System.monotonic_time(:millisecond) - start_time
          persist_child_session(final_session, workspace)

          # Record performance metrics
          Review.record_performance(subagent_module, %{
            task_type: "#{profile.name}:#{label}",
            success: true,
            duration_ms: duration,
            tool_calls: extract_tool_calls(final_session),
            user_feedback: nil
          })

          result = render_runner_result(result)

          send(server, {:task_complete, task_id, result, profile.return_mode})

          announce_result(
            task_id,
            label,
            task_description,
            result,
            channel,
            chat_id,
            workspace,
            profile,
            :ok
          )

        {:error, reason, final_session} ->
          duration = System.monotonic_time(:millisecond) - start_time
          error_msg = inspect(reason)
          persist_child_session(final_session, workspace)

          # Record failure metrics
          Review.record_performance(subagent_module, %{
            task_type: "#{profile.name}:#{label}",
            success: false,
            duration_ms: duration,
            tool_calls: extract_tool_calls(final_session),
            user_feedback: nil
          })

          send(server, {:task_failed, task_id, error_msg, profile.return_mode})

          announce_result(
            task_id,
            label,
            task_description,
            error_msg,
            channel,
            chat_id,
            workspace,
            profile,
            :error
          )
      end
    rescue
      e ->
        error_msg = Exception.message(e)
        send(server, {:task_failed, task_id, error_msg, profile.return_mode})

        announce_result(
          task_id,
          label,
          task_description,
          error_msg,
          channel,
          chat_id,
          workspace,
          profile,
          :error
        )
    end
  end

  defp announce_result(
         task_id,
         label,
         _task,
         result,
         channel,
         chat_id,
         workspace,
         profile,
         status
       ) do
    if Process.whereis(Bus) != nil and profile.return_mode == :inbound do
      status_emoji = if status == :ok, do: "\u2705", else: "\u274c"
      status_label = if status == :ok, do: "finished", else: "failed"

      content =
        [
          "#{status_emoji} Subagent task #{status_label}",
          "Task ID: #{task_id}",
          "Profile: #{profile.name}",
          "Label: #{label}",
          "Child session: subagent:#{task_id}",
          "Lifecycle: task-scoped child run; it will not remain in `run.owner.current`, which only lists active owner runs.",
          "Result:\n#{result}"
        ]
        |> Enum.join("\n")

      Bus.publish(:inbound, %Envelope{
        channel: channel || "system",
        chat_id: chat_id || "default",
        sender_id: "subagent",
        text: content,
        message_type: :text,
        raw: %{"task_id" => task_id, "label" => label, "status" => status},
        metadata: %{
          "_from_subagent" => true,
          "subagent_task_id" => task_id,
          "subagent_label" => label,
          "subagent_profile" => profile.name,
          "origin_channel" => channel,
          "origin_chat_id" => chat_id,
          "workspace" => workspace
        },
        media_refs: [],
        attachments: []
      })
    end
  end

  # --- Helpers ---

  defp resolve_profile(opts, config, runtime_snapshot, workspace) do
    profiles =
      case runtime_snapshot do
        %Snapshot{subagents: %{profiles: profiles}} when is_map(profiles) ->
          profiles

        _ ->
          Profiles.load(config, workspace: workspace)
      end

    profiles
    |> Profiles.get(Keyword.get(opts, :profile))
    |> apply_profile_overrides(opts)
  end

  defp apply_profile_overrides(%Profile{} = profile, opts) do
    attrs =
      %{
        "name" => profile.name,
        "description" => profile.description,
        "prompt" => profile.prompt,
        "model_role" => profile.model_role,
        "model_key" => profile.model_key,
        "provider_options" => Map.new(profile.provider_options || []),
        "tools_filter" => profile.tools_filter,
        "tool_allowlist" => profile.tool_allowlist,
        "context_mode" => profile.context_mode,
        "context_window" => profile.context_window,
        "return_mode" => profile.return_mode,
        "max_iterations" => profile.max_iterations
      }
      |> maybe_put_override("model_role", Keyword.get(opts, :model_role))
      |> maybe_put_override("model_key", Keyword.get(opts, :model_key))
      |> maybe_put_override("context_mode", Keyword.get(opts, :context_mode))
      |> maybe_put_override("return_mode", Keyword.get(opts, :return_mode))

    case Profile.from_map(profile.name, attrs, source: profile.source) do
      {:ok, updated} -> updated
      {:error, _reason} -> profile
    end
  end

  defp maybe_put_override(attrs, _key, value) when value in [nil, ""], do: attrs
  defp maybe_put_override(attrs, key, value), do: Map.put(attrs, key, value)

  defp resolve_model_runtime(%Profile{model_key: model_key}, %Config{} = config)
       when is_binary(model_key) do
    case Config.model_runtime(config, model_key) do
      {:ok, runtime} -> runtime
      {:error, _reason} -> nil
    end
  end

  defp resolve_model_runtime(%Profile{model_role: role}, %Config{} = config)
       when role not in [nil, :inherit] do
    Config.model_role(config, role)
  end

  defp resolve_model_runtime(_profile, _config), do: nil

  defp runtime_config(%Snapshot{config: config}), do: config
  defp runtime_config(_), do: nil

  defp model_runtime_value(nil, _key), do: nil
  defp model_runtime_value(runtime, key) when is_map(runtime), do: Map.get(runtime, key)

  defp build_profile_prompt(
         %Profile{} = profile,
         task_id,
         task_description,
         label,
         opts,
         workspace,
         parent_key
       ) do
    explicit_context = Keyword.get(opts, :context)
    parent_context = parent_context(profile, workspace, parent_key)

    [
      String.trim(profile.prompt || default_profile_prompt()),
      subagent_identity_block(profile, task_id, label),
      context_block("Provided context", explicit_context),
      context_block("Recent parent session context", parent_context),
      "Task:\n#{task_description}"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp default_profile_prompt do
    """
    You are a task-scoped background subagent child run. Complete the assigned task independently and return a concise final result.
    """
  end

  defp subagent_identity_block(%Profile{} = profile, task_id, label) do
    """
    Subagent identity:
    Task ID: #{task_id}
    Profile: #{profile.name}
    Label: #{label}
    Child session: subagent:#{task_id}
    Lifecycle: task-scoped background child run. Finish the assigned task and return the final result; do not describe yourself as a persistent owner run.
    Observation note: `run.owner.current` tracks active owner runs only, not completed subagent tasks.
    """
    |> String.trim()
  end

  defp context_block(_title, value) when value in [nil, ""], do: nil

  defp context_block(title, value) when is_binary(value) do
    """
    #{title}:
    #{String.trim(value)}
    """
    |> String.trim()
  end

  defp context_block(_title, _value), do: nil

  defp parent_context(%Profile{context_mode: :parent_recent} = profile, workspace, parent_key)
       when is_binary(parent_key) do
    opts = if is_binary(workspace), do: [workspace: workspace], else: []

    session =
      if Process.whereis(SessionManager) do
        SessionManager.get(parent_key, opts) || Session.load(parent_key, opts)
      else
        Session.load(parent_key, opts)
      end

    case session do
      %Session{} = session ->
        session
        |> Session.get_history(profile.context_window || 12)
        |> Enum.map_join("\n", fn message ->
          role = Map.get(message, "role", "unknown")
          content = Map.get(message, "content", "") |> to_string() |> String.trim()
          "#{role}: #{String.slice(content, 0, 1200)}"
        end)

      _ ->
        nil
    end
  end

  defp parent_context(_profile, _workspace, _parent_key), do: nil

  defp persist_child_session(%Session{} = session, workspace) do
    opts = if is_binary(workspace), do: [workspace: workspace], else: []
    Session.save(session, opts)
  rescue
    _ -> :ok
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp update_task(state, task_id, new_status, fields) do
    case Map.get(state.tasks, task_id) do
      nil ->
        state

      task ->
        updated =
          task
          |> Map.put(:status, new_status)
          |> Map.put(:completed_at, System.system_time(:second))
          |> Map.merge(Map.new(fields))

        if publish_task_event?(updated) do
          Bus.publish(:subagent, %{
            type: new_status,
            task_id: task_id,
            result: updated[:result],
            error: updated[:error]
          })
        end

        new_tasks = Map.put(state.tasks, task_id, updated)
        %{state | tasks: cleanup_old_tasks(new_tasks)}
    end
  end

  defp cleanup_old_tasks(tasks) do
    completed_tasks =
      tasks
      |> Enum.filter(fn {_id, task} -> task.status in [:completed, :failed, :cancelled] end)
      |> Enum.sort_by(fn {_id, task} -> task.completed_at || 0 end, :desc)

    if length(completed_tasks) > @max_completed_tasks do
      tasks_to_remove = Enum.drop(completed_tasks, @max_completed_tasks) |> Enum.map(&elem(&1, 0))
      Map.drop(tasks, tasks_to_remove)
    else
      tasks
    end
  end

  defp publish_task_event?(%{return_mode: :silent}), do: false
  defp publish_task_event?(_task), do: Process.whereis(Bus) != nil

  defp find_task_by_pid(state, pid) do
    Enum.find(state.tasks, fn {_id, task} -> task.pid == pid end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp workspace_match?(_task_workspace, nil), do: true

  defp workspace_match?(task_workspace, workspace),
    do: Path.expand(task_workspace || "") == Path.expand(workspace)

  defp extract_tool_calls(session) do
    session.messages
    |> Enum.filter(fn msg -> msg["role"] == "assistant" end)
    |> Enum.flat_map(fn msg ->
      tool_calls = msg["tool_calls"] || []

      Enum.map(tool_calls, fn tc ->
        get_in(tc, ["function", "name"]) || "unknown"
      end)
    end)
    |> Enum.uniq()
  end

  defp render_runner_result(%Nex.Agent.Stream.Result{} = result), do: to_string(result)
  defp render_runner_result(result), do: result
end
