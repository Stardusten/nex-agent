defmodule Nex.Agent.Tool.Registry do
  @moduledoc """
  Tool Registry - dynamic registration/unregistration/hot-swap of tool modules.
  Central place to manage all agent tools.
  """

  use GenServer
  require Logger

  alias Nex.Agent.ControlPlane.{Log, Redactor}
  alias Nex.Agent.FollowUp
  require Log

  @default_tools [
    Nex.Agent.Tool.Read,
    Nex.Agent.Tool.Find,
    Nex.Agent.Tool.ApplyPatch,
    Nex.Agent.Tool.Bash,
    Nex.Agent.Tool.WebSearch,
    Nex.Agent.Tool.ImageGeneration,
    Nex.Agent.Tool.WebFetch,
    Nex.Agent.Tool.Message,
    Nex.Agent.Tool.AskAdvisor,
    Nex.Agent.Tool.Observe,
    Nex.Agent.Tool.Task,
    Nex.Agent.Tool.KnowledgeCapture,
    Nex.Agent.Tool.ExecutorDispatch,
    Nex.Agent.Tool.ExecutorStatus,
    Nex.Agent.Tool.InterruptSession,
    Nex.Agent.Tool.MemoryConsolidate,
    Nex.Agent.Tool.MemoryStatus,
    Nex.Agent.Tool.MemoryRebuild,
    Nex.Agent.Tool.MemoryWrite,
    Nex.Agent.Tool.Hook,
    Nex.Agent.Tool.UserUpdate,
    Nex.Agent.Tool.SkillGet,
    Nex.Agent.Tool.SkillCapture,
    Nex.Agent.Tool.ToolCreate,
    Nex.Agent.Tool.ToolList,
    Nex.Agent.Tool.ToolDelete,
    Nex.Agent.Tool.SoulUpdate,
    Nex.Agent.Tool.SpawnTask,
    Nex.Agent.Tool.SelfUpdate,
    Nex.Agent.Tool.Reflect,
    Nex.Agent.Tool.EvolutionCandidate,
    Nex.Agent.Tool.Cron
  ]
  @disabled_project_tools [
    Nex.Agent.Tool.SkillCreate
  ]

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Register a tool module."
  def register(module) do
    GenServer.cast(__MODULE__, {:register, module})
  end

  @doc "Unregister a tool by name."
  def unregister(name) do
    GenServer.cast(__MODULE__, {:unregister, name})
  end

  @doc "Atomic hot-swap: unregister old + register new."
  def hot_swap(name, new_module) do
    GenServer.cast(__MODULE__, {:hot_swap, name, new_module})
  end

  @doc """
  Get tool definitions for LLM.
  Filter: :all | :base | :subagent
  """
  def definitions(filter \\ :all, opts \\ []) do
    GenServer.call(__MODULE__, {:definitions, filter, opts})
  end

  @doc "Execute a tool by name."
  def execute(name, args, ctx \\ %{}) do
    timeout = execute_timeout(ctx)
    GenServer.call(__MODULE__, {:execute, name, args, ctx, timeout}, timeout + 1_000)
  end

  @doc "Cancel active tool tasks for a run."
  def cancel_run(run_id) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:cancel_run, run_id})
  end

  @doc "List all registered tool names."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Re-scan built-in, project, and custom tools."
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Get module for a tool name."
  def get(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc "List default built-in tool names."
  def builtin_names do
    @default_tools
    |> Enum.map(fn module ->
      if function_exported?(module, :name, 0), do: module.name(), else: nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Server

  @impl true
  def init(_opts) do
    tools = build_tools()

    Logger.info(
      "[Registry] Started with #{map_size(tools)} tools: #{inspect(Map.keys(tools) |> Enum.sort())}"
    )

    {:ok, %{tools: tools, active_runs: %{}, active_tasks: %{}}}
  end

  @impl true
  def handle_cast({:register, module}, %{tools: tools} = state) do
    case safe_tool_name(module) do
      {:ok, name} ->
        case maybe_register_runtime_tool(tools, name, module) do
          {:ok, updated_tools} ->
            {:noreply, %{state | tools: updated_tools}}

          {:error, reason} ->
            Logger.warning(
              "[Registry] Failed to register runtime tool #{inspect(module)}: #{reason}"
            )

            {:noreply, state}
        end

      :error ->
        Logger.warning("[Registry] Failed to register module: #{inspect(module)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:unregister, name}, %{tools: tools} = state) do
    {:noreply, %{state | tools: Map.delete(tools, name)}}
  end

  @impl true
  def handle_cast({:hot_swap, name, new_module}, %{tools: tools} = state) do
    case safe_tool_name(new_module) do
      {:ok, new_name} ->
        case maybe_hot_swap_runtime_tool(tools, name, new_name, new_module) do
          {:ok, updated_tools} ->
            Logger.info("[Registry] Hot-swapped #{name} -> #{new_name}")
            {:noreply, %{state | tools: updated_tools}}

          {:error, reason} ->
            Logger.warning("[Registry] Hot-swap rejected for #{name}: #{reason}")
            {:noreply, state}
        end

      :error ->
        Logger.warning(
          "[Registry] Hot-swap failed for #{name}: module doesn't implement callbacks"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:definitions, filter, opts}, _from, %{tools: tools} = state) do
    defs =
      tools
      |> filter_tools(filter)
      |> Enum.sort_by(fn {name, _module} -> {definition_priority(name), name} end)
      |> Enum.map(fn {name, module} ->
        tool_definition(module, opts)
        |> normalize_tool_definition(name)
      end)
      |> Enum.reject(&is_nil/1)

    {:reply, defs, state}
  end

  @impl true
  def handle_call({:execute, name, args, ctx, timeout}, from, %{tools: tools} = state) do
    started_at = System.monotonic_time(:millisecond)
    observe_opts = observe_opts(ctx)
    attrs = execute_attrs(name, args)

    case Map.get(tools, name) do
      nil ->
        emit_observation(
          :error,
          "tool.registry.execute.failed",
          Map.put(attrs, "result_status", "error"),
          observe_opts
        )

        {:reply,
         {:error, "Unknown tool: #{name}. [Analyze the error and try a different approach.]"},
         state}

      module ->
        run_id = run_id_from_ctx(ctx)
        server = self()
        emit_observation(:info, "tool.registry.execute.started", attrs, observe_opts)

        {:ok, pid} =
          Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
            result =
              try do
                module.execute(args, ctx)
              rescue
                e ->
                  {:error,
                   "Tool #{name} crashed: #{Exception.message(e)}. [Analyze the error and try a different approach.]"}
              catch
                :exit, {:timeout, _} ->
                  {:error,
                   "Tool #{name} timed out. [Analyze the error and try a different approach.]"}

                kind, reason ->
                  {:error,
                   "Tool #{name} failed: #{kind} #{inspect(reason)}. [Analyze the error and try a different approach.]"}
              end

            send(server, {:tool_finished, run_id, self(), from, result})
          end)

        monitor_ref = Process.monitor(pid)
        timer_ref = Process.send_after(self(), {:tool_timeout, pid}, timeout)

        task_meta = %{
          from: from,
          run_id: run_id,
          attrs: attrs,
          opts: observe_opts,
          started_at: started_at,
          monitor_ref: monitor_ref,
          timer_ref: timer_ref
        }

        state =
          state
          |> put_active_run(run_id, pid)
          |> put_in([:active_tasks, pid], task_meta)

        {:noreply, state}
    end
  end

  def handle_call({:cancel_run, run_id}, _from, state) do
    pids = Map.get(state.active_runs, run_id, MapSet.new())

    state =
      Enum.reduce(pids, state, fn pid, acc ->
        case Map.get(acc.active_tasks, pid) do
          nil ->
            acc

          meta ->
            Process.exit(pid, :kill)
            Process.demonitor(meta.monitor_ref, [:flush])
            Process.cancel_timer(meta.timer_ref)

            GenServer.reply(
              meta.from,
              {:error,
               "Tool execution cancelled. [Analyze the error and try a different approach.]"}
            )

            emit_observation(
              :warning,
              "tool.registry.execute.cancelled",
              meta.attrs
              |> Map.put("duration_ms", duration_since(meta.started_at))
              |> Map.put("result_status", "cancelled")
              |> Map.put("reason_type", "cancelled"),
              meta.opts
            )

            %{acc | active_tasks: Map.delete(acc.active_tasks, pid)}
        end
      end)

    {:reply, :ok, %{state | active_runs: Map.delete(state.active_runs, run_id)}}
  end

  @impl true
  def handle_call(:list, _from, %{tools: tools} = state) do
    {:reply, Map.keys(tools), state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    tools = build_tools()
    {:reply, :ok, %{state | tools: tools}}
  end

  @impl true
  def handle_call({:get, name}, _from, %{tools: tools} = state) do
    {:reply, Map.get(tools, name), state}
  end

  @impl true
  def handle_info({:tool_finished, run_id, pid, from, result}, state) do
    meta = Map.get(state.active_tasks, pid)

    if meta do
      Process.demonitor(meta.monitor_ref, [:flush])
      Process.cancel_timer(meta.timer_ref)
      emit_execute_finished(result, meta)
    end

    GenServer.reply(from, result)

    active_runs =
      case run_id do
        run_id when is_binary(run_id) ->
          state.active_runs
          |> Map.update(run_id, MapSet.new(), &MapSet.delete(&1, pid))
          |> drop_empty_run(run_id)

        _ ->
          state.active_runs
      end

    {:noreply,
     %{state | active_runs: active_runs, active_tasks: Map.delete(state.active_tasks, pid)}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.get(state.active_tasks, pid) do
      nil ->
        {:noreply, state}

      meta ->
        Process.cancel_timer(meta.timer_ref)

        GenServer.reply(
          meta.from,
          {:error,
           "Tool execution exited: #{inspect(reason)}. [Analyze the error and try a different approach.]"}
        )

        emit_observation(
          :error,
          "tool.registry.execute.failed",
          meta.attrs
          |> Map.put("duration_ms", duration_since(meta.started_at))
          |> Map.put("result_status", "error")
          |> Map.put("reason_type", "exit"),
          meta.opts
        )

        active_runs =
          case meta.run_id do
            run_id when is_binary(run_id) ->
              state.active_runs
              |> Map.update(run_id, MapSet.new(), &MapSet.delete(&1, pid))
              |> drop_empty_run(run_id)

            _ ->
              state.active_runs
          end

        {:noreply,
         %{state | active_runs: active_runs, active_tasks: Map.delete(state.active_tasks, pid)}}
    end
  end

  def handle_info({:tool_timeout, pid}, state) do
    case Map.get(state.active_tasks, pid) do
      nil ->
        {:noreply, state}

      meta ->
        Process.exit(pid, :kill)
        Process.demonitor(meta.monitor_ref, [:flush])

        GenServer.reply(
          meta.from,
          {:error, "Tool execution timed out. [Analyze the error and try a different approach.]"}
        )

        emit_observation(
          :error,
          "tool.registry.execute.timeout",
          meta.attrs
          |> Map.put("duration_ms", duration_since(meta.started_at))
          |> Map.put("result_status", "timeout")
          |> Map.put("reason_type", "timeout"),
          meta.opts
        )

        active_runs =
          case meta.run_id do
            run_id when is_binary(run_id) ->
              state.active_runs
              |> Map.update(run_id, MapSet.new(), &MapSet.delete(&1, pid))
              |> drop_empty_run(run_id)

            _ ->
              state.active_runs
          end

        {:noreply,
         %{state | active_runs: active_runs, active_tasks: Map.delete(state.active_tasks, pid)}}
    end
  end

  # Helpers

  defp safe_tool_name(module) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, :name, 0) ->
        {:ok, module.name()}

      function_exported?(module, :definition, 0) ->
        def_map = module.definition()
        name = get_def_name(def_map)
        if name, do: {:ok, name}, else: :error

      true ->
        :error
    end
  end

  defp tool_definition(module, opts) do
    cond do
      function_exported?(module, :definition, 1) -> module.definition(opts)
      function_exported?(module, :definition, 0) -> module.definition()
      true -> nil
    end
  end

  defp normalize_tool_definition(nil, _fallback_name), do: nil

  defp normalize_tool_definition(definition, fallback_name) when is_map(definition) do
    def_map = normalize_definition(definition)

    %{
      "name" => get_def_name(def_map) || fallback_name,
      "description" => get_def_description(def_map),
      "input_schema" => get_def_params(def_map)
    }
  end

  # Scan repo tool directory for modules not in @default_tools.
  defp discover_project_tool_modules do
    tool_dir = Path.join([File.cwd!(), "lib", "nex", "agent", "tool"])

    if File.dir?(tool_dir) do
      tool_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.flat_map(fn file ->
        # Extract actual module name from source file instead of guessing from filename
        filepath = Path.join(tool_dir, file)

        case extract_module_name(filepath) do
          {:ok, module}
          when module not in @default_tools and module not in @disabled_project_tools ->
            # Try loading compiled beam first; if missing, compile the source file
            case Code.ensure_loaded(module) do
              {:module, _} ->
                :ok

              {:error, _} ->
                try do
                  Code.compile_file(filepath)
                rescue
                  e ->
                    Logger.warning(
                      "[Registry] Failed to compile #{filepath}: #{Exception.message(e)}"
                    )
                end
            end

            if function_exported?(module, :name, 0) do
              Logger.info("[Registry] Discovered project tool: #{inspect(module)}")
              [module]
            else
              []
            end

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  defp discover_custom_tool_modules do
    alias Nex.Agent.Tool.CustomTools

    CustomTools.ensure_root_dir()

    CustomTools.list()
    |> Enum.flat_map(fn tool ->
      case CustomTools.load_module_from_source(tool.source_path) do
        {:ok, module} ->
          Logger.info("[Registry] Discovered custom tool: #{inspect(module)}")
          [module]

        {:error, reason} ->
          Logger.warning("[Registry] Failed to load custom tool #{tool["name"]}: #{reason}")
          []
      end
    end)
  end

  defp register_modules(acc, modules, source) do
    Enum.reduce(modules, acc, fn module, tools ->
      case safe_tool_name(module) do
        {:ok, name} ->
          if Map.has_key?(tools, name) do
            Logger.warning(
              "[Registry] Skipping #{source} tool with conflicting name #{name}: #{inspect(module)}"
            )

            tools
          else
            Map.put(tools, name, module)
          end

        :error ->
          Logger.warning("[Registry] Failed to register #{source} tool: #{inspect(module)}")
          tools
      end
    end)
  end

  defp build_tools do
    %{}
    |> register_modules(@default_tools, "default")
    |> register_modules(discover_project_tool_modules(), "project")
    |> register_modules(discover_custom_tool_modules(), "custom")
  end

  defp maybe_register_runtime_tool(tools, name, module) do
    case Map.get(tools, name) do
      nil ->
        {:ok, Map.put(tools, name, module)}

      ^module ->
        {:ok, tools}

      existing ->
        {:error, "tool name #{name} is already registered to #{inspect(existing)}"}
    end
  end

  defp maybe_hot_swap_runtime_tool(tools, old_name, new_name, module) do
    case Map.get(tools, old_name) do
      nil ->
        {:error, "existing tool #{old_name} is not registered"}

      existing when old_name == new_name ->
        if existing == module do
          {:ok, tools}
        else
          {:ok, Map.put(tools, new_name, module)}
        end

      _existing ->
        if Map.has_key?(tools, new_name) do
          {:error, "tool name #{new_name} is already registered"}
        else
          {:ok, tools |> Map.delete(old_name) |> Map.put(new_name, module)}
        end
    end
  end

  # Parse `defmodule Nex.Agent.Tool.Foo do` from source file.
  defp extract_module_name(filepath) do
    case File.open(filepath, [:read]) do
      {:ok, device} ->
        result = scan_for_module(device)
        File.close(device)
        result

      _ ->
        :error
    end
  end

  defp scan_for_module(device) do
    case IO.read(device, :line) do
      :eof ->
        :error

      {:error, _} ->
        :error

      line ->
        case Regex.run(~r/defmodule\s+([\w.]+)/, line) do
          [_, module_str] -> {:ok, Module.concat([module_str])}
          nil -> scan_for_module(device)
        end
    end
  end

  defp get_def_name(%{name: n}), do: n
  defp get_def_name(%{"name" => n}), do: n
  defp get_def_name(_), do: nil

  defp get_def_description(%{description: d}), do: d
  defp get_def_description(%{"description" => d}), do: d
  defp get_def_description(_), do: ""

  defp get_def_params(%{parameters: p}), do: p
  defp get_def_params(%{"parameters" => p}), do: p
  defp get_def_params(%{input_schema: p}), do: p
  defp get_def_params(%{"input_schema" => p}), do: p
  defp get_def_params(_), do: %{"type" => "object", "properties" => %{}}

  # Unwrap OpenAI-style nested definition: %{type: "function", function: %{name, description, parameters}}
  defp normalize_definition(%{function: inner}) when is_map(inner), do: inner
  defp normalize_definition(%{"function" => inner}) when is_map(inner), do: inner
  defp normalize_definition(def_map), do: def_map

  defp definition_priority("memory_consolidate"), do: 0
  defp definition_priority("memory_status"), do: 1
  defp definition_priority("memory_rebuild"), do: 2
  defp definition_priority("memory_write"), do: 3
  defp definition_priority(_name), do: 100

  @cron_tools ~w(bash read message web_search web_fetch task)
  @subagent_tools ~w(
    apply_patch
    bash
    executor_dispatch
    executor_status
    find
    memory_status
    read
    reflect
    skill_get
    web_fetch
    web_search
  )

  defp filter_tools(tools, :all), do: tools

  defp filter_tools(tools, :follow_up) do
    Enum.filter(tools, fn {_name, module} ->
      module
      |> then(& &1.definition())
      |> normalize_definition()
      |> FollowUp.allowed_tool_definition?()
    end)
  end

  defp filter_tools(tools, :cron) do
    Enum.filter(tools, fn {name, _module} -> name in @cron_tools end)
  end

  defp filter_tools(tools, :base) do
    Enum.filter(tools, fn {_name, module} ->
      if function_exported?(module, :category, 0) do
        module.category() == :base
      else
        true
      end
    end)
  end

  defp filter_tools(tools, :subagent) do
    Enum.filter(tools, fn {name, _module} -> name in @subagent_tools end)
  end

  defp run_id_from_ctx(ctx) when is_map(ctx) do
    Map.get(ctx, :run_id) || Map.get(ctx, "run_id")
  end

  defp execute_timeout(ctx) when is_map(ctx) do
    case Map.get(ctx, :timeout) || Map.get(ctx, "timeout") || Map.get(ctx, :timeout_ms) ||
           Map.get(ctx, "timeout_ms") do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> 120_000
    end
  end

  defp execute_timeout(_ctx), do: 120_000

  defp put_active_run(state, run_id, pid) when is_binary(run_id) do
    put_in(state.active_runs[run_id], track_tool_pid(Map.get(state.active_runs, run_id), pid))
  end

  defp put_active_run(state, _run_id, _pid), do: state

  defp track_tool_pid(nil, pid), do: MapSet.new([pid])
  defp track_tool_pid(%MapSet{} = pids, pid), do: MapSet.put(pids, pid)

  defp drop_empty_run(active_runs, run_id) do
    case Map.get(active_runs, run_id) do
      %MapSet{} = pids ->
        if MapSet.size(pids) == 0, do: Map.delete(active_runs, run_id), else: active_runs

      _ ->
        active_runs
    end
  end

  defp emit_execute_finished({:ok, _result}, meta) do
    emit_observation(
      :info,
      "tool.registry.execute.finished",
      meta.attrs
      |> Map.put("duration_ms", duration_since(meta.started_at))
      |> Map.put("result_status", "ok"),
      meta.opts
    )
  end

  defp emit_execute_finished({:error, reason}, meta) do
    emit_observation(
      :error,
      "tool.registry.execute.failed",
      meta.attrs
      |> Map.put("duration_ms", duration_since(meta.started_at))
      |> Map.put("result_status", "error")
      |> Map.put("reason_type", reason_type(reason))
      |> Map.put("error_summary", error_summary(reason)),
      meta.opts
    )
  end

  defp emit_execute_finished(_result, meta) do
    emit_observation(
      :info,
      "tool.registry.execute.finished",
      meta.attrs
      |> Map.put("duration_ms", duration_since(meta.started_at))
      |> Map.put("result_status", "ok"),
      meta.opts
    )
  end

  defp execute_attrs(name, args) do
    %{
      "tool_name" => to_string(name),
      "args_summary" => args_summary(args)
    }
  end

  defp observe_opts(ctx) when is_map(ctx) do
    []
    |> put_ctx_opt(:workspace, ctx)
    |> put_ctx_opt(:run_id, ctx)
    |> put_ctx_opt(:session_key, ctx)
    |> put_ctx_opt(:channel, ctx)
    |> put_ctx_opt(:chat_id, ctx)
    |> put_ctx_opt(:tool_call_id, ctx)
    |> put_ctx_opt(:trace_id, ctx)
  end

  defp observe_opts(_ctx), do: []

  defp put_ctx_opt(opts, key, ctx) do
    case Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key)) do
      nil -> opts
      value -> Keyword.put(opts, key, value)
    end
  end

  defp emit_observation(level, tag, attrs, opts) do
    case level do
      :info -> Log.info(tag, attrs, opts)
      :warning -> Log.warning(tag, attrs, opts)
      :error -> Log.error(tag, attrs, opts)
    end

    :ok
  rescue
    e ->
      Logger.warning("[Registry] control-plane log #{tag} crashed: #{Exception.message(e)}")
      :ok
  end

  defp duration_since(started_at), do: System.monotonic_time(:millisecond) - started_at

  defp reason_type(reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "timed out") -> "timeout"
      String.contains?(reason, "crashed") -> "exception"
      true -> "error"
    end
  end

  defp reason_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_type(_reason), do: "error"

  defp error_summary(reason), do: reason |> to_string() |> String.slice(0, 1000)

  defp args_summary(args) do
    args
    |> Redactor.redact()
    |> inspect(limit: 20, printable_limit: 1000)
    |> String.slice(0, 1000)
  end
end
