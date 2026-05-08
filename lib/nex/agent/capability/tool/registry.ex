defmodule Nex.Agent.Capability.Tool.Registry do
  @moduledoc """
  Tool Registry - dynamic registration/unregistration/hot-swap of tool modules.
  Central place to manage all agent tools.
  """

  use GenServer
  require Logger

  alias Nex.Agent.Observe.ControlPlane.{Log, Redactor}
  alias Nex.Agent.Conversation.FollowUp
  alias Nex.Agent.Extension.Plugin.Catalog, as: PluginCatalog
  alias Nex.Agent.Interface.MCP.ServerManager, as: MCPServerManager
  alias Nex.Agent.Runtime
  alias Nex.Agent.Self.CodeUpgrade
  require Log

  @core_tools [
    Nex.Agent.Capability.Tool.Core.AddPermissionRule,
    Nex.Agent.Capability.Tool.Core.PermissionListRules,
    Nex.Agent.Capability.Tool.Core.PermissionRevokeRule,
    Nex.Agent.Capability.Tool.Core.PermissionRuleDebug,
    Nex.Agent.Capability.Tool.Core.Read,
    Nex.Agent.Capability.Tool.Core.Find,
    Nex.Agent.Capability.Tool.Core.ApplyPatch,
    Nex.Agent.Capability.Tool.Core.Bash,
    Nex.Agent.Capability.Tool.Core.Message,
    Nex.Agent.Capability.Tool.Core.Observe,
    Nex.Agent.Capability.Tool.Core.KnowledgeCapture,
    Nex.Agent.Capability.Tool.Core.ExecutorDispatch,
    Nex.Agent.Capability.Tool.Core.ExecutorStatus,
    Nex.Agent.Capability.Tool.Core.InterruptSession,
    Nex.Agent.Capability.Tool.Core.Hook,
    Nex.Agent.Capability.Tool.Core.UserUpdate,
    Nex.Agent.Capability.Tool.Core.SkillGet,
    Nex.Agent.Capability.Tool.Core.SkillCapture,
    Nex.Agent.Capability.Tool.Core.ToolCreate,
    Nex.Agent.Capability.Tool.Core.ToolList,
    Nex.Agent.Capability.Tool.Core.ToolDelete,
    Nex.Agent.Capability.Tool.Core.SoulUpdate,
    Nex.Agent.Capability.Tool.Core.SpawnTask,
    Nex.Agent.Capability.Tool.Core.SelfUpdate,
    Nex.Agent.Capability.Tool.Core.SelfUpdateCommit,
    Nex.Agent.Capability.Tool.Core.Reflect
  ]
  @disabled_project_tools [
    Nex.Agent.Capability.Tool.Core.SkillCreate
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

  @doc "Get the raw registry entry for a tool name."
  def get(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc "Get the backing module for a tool name when one exists."
  def module_for(name) do
    GenServer.call(__MODULE__, {:module_for, name})
  end

  @doc "Get a normalized description record for a tool name."
  def describe(name, opts \\ []) do
    GenServer.call(__MODULE__, {:describe, name, opts})
  end

  @doc "List default built-in tool names."
  def builtin_names do
    builtin_tool_modules()
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
      |> project_tools(opts)
      |> filter_tools(filter, opts)
      |> Enum.sort_by(fn {name, _entry} -> {definition_priority(name), name} end)
      |> Enum.map(fn {name, entry} ->
        tool_definition(entry, opts)
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
    available_tools = project_tools(tools, tool_projection_opts(ctx))

    case Map.get(available_tools, name) do
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

      entry ->
        run_id = run_id_from_ctx(ctx)
        server = self()
        emit_observation(:info, "tool.registry.execute.started", attrs, observe_opts)

        {:ok, pid} =
          Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
            result =
              try do
                execute_tool_entry(name, entry, args, ctx)
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

  def handle_call({:module_for, name}, _from, %{tools: tools} = state) do
    {:reply, entry_module(Map.get(tools, name)), state}
  end

  def handle_call({:describe, name, opts}, _from, %{tools: tools} = state) do
    entry =
      tools
      |> project_tools(tool_projection_opts_from_describe_opts(opts))
      |> Map.get(name)

    description =
      if entry do
        %{
          "name" => name,
          "module" => entry_module_display(entry),
          "description" => entry_description(entry),
          "definition" => tool_definition(entry, opts),
          "source_path" => entry_source_path(entry),
          "layers" => entry_layers(entry),
          "plugin_id" => entry_plugin_id(entry),
          "entry_type" => entry_type(entry)
        }
      end

    {:reply, description, state}
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
      is_map(module) and Map.get(module, "entry_type") == "plugin_mcp" ->
        plugin_mcp_definition(module)

      is_map(module) and Map.get(module, "entry_type") == "plugin_module" ->
        case module
             |> Map.fetch!("module")
             |> tool_definition(opts) do
          %{} = definition ->
            definition
            |> normalize_definition()
            |> Map.put("name", plugin_entry_name(module) || Map.get(module, "id"))

          _ ->
            nil
        end

      true ->
        module_tool_definition(module, opts)
    end
  end

  defp module_tool_definition(module, opts) do
    cond do
      function_exported?(module, :definition, 1) -> module.definition(opts)
      function_exported?(module, :definition, 0) -> module.definition()
      true -> nil
    end
  end

  defp plugin_mcp_definition(%{"attrs" => %{} = attrs, "id" => id}) do
    %{
      "name" => Map.get(attrs, "name", id),
      "description" => Map.get(attrs, "description", "Plugin MCP tool"),
      "input_schema" => Map.get(attrs, "parameters", %{"type" => "object", "properties" => %{}})
    }
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

  # Scan repo tool directory for modules not in core or enabled builtin plugin tools.
  defp discover_project_tool_modules do
    tool_dir = Path.join([File.cwd!(), "lib", "nex", "agent", "tool"])
    builtin_modules = builtin_tool_modules()

    if File.dir?(tool_dir) do
      tool_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.flat_map(fn file ->
        # Extract actual module name from source file instead of guessing from filename
        filepath = Path.join(tool_dir, file)

        case extract_module_name(filepath) do
          {:ok, module} ->
            if module in builtin_modules or module in @disabled_project_tools do
              []
            else
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
    alias Nex.Agent.Capability.Tool.CustomTools

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

  defp builtin_tool_modules do
    @core_tools
  end

  defp plugin_tool_names(opts) do
    opts
    |> plugin_tool_contributions()
    |> Enum.map(& &1["id"])
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  defp plugin_tool_contributions(opts) do
    cond do
      Keyword.has_key?(opts, :plugin_data) or Keyword.has_key?(opts, :plugins) ->
        PluginCatalog.contributions("tools", opts)

      Keyword.has_key?(opts, :config) ->
        PluginCatalog.contributions("tools", config: Keyword.fetch!(opts, :config))

      true ->
        case Runtime.current() do
          {:ok, %{plugins: plugins}} -> PluginCatalog.contributions("tools", plugin_data: plugins)
          _ -> PluginCatalog.contributions("tools", opts)
        end
    end
  end

  defp plugin_tool_entries(opts) do
    opts
    |> plugin_tool_contributions()
    |> Enum.map(&tool_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp tool_entry(%{"attrs" => %{} = attrs} = contribution) do
    attrs = normalize_plugin_tool_attrs(attrs)

    cond do
      is_binary(Map.get(attrs, "from")) and String.starts_with?(Map.get(attrs, "from"), "mcp:") ->
        contribution
        |> Map.put("attrs", attrs)
        |> Map.put("entry_type", "plugin_mcp")

      module = tool_module_from_attrs(attrs) ->
        %{
          "entry_type" => "plugin_module",
          "module" => module,
          "plugin_id" => contribution["plugin_id"],
          "id" => contribution["id"],
          "attrs" => attrs
        }

      true ->
        nil
    end
  end

  defp tool_entry(_contribution), do: nil

  defp tool_module_from_attrs(%{} = attrs) do
    module_name =
      case Map.get(attrs, "from") do
        "module:" <> module_name -> module_name
        _ -> Map.get(attrs, "module")
      end

    with module_name when is_binary(module_name) <- module_name,
         module <- Module.concat(String.split(module_name, ".")),
         {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :execute, 2),
         true <-
           function_exported?(module, :definition, 0) or
             function_exported?(module, :definition, 1) do
      module
    else
      _ -> nil
    end
  end

  defp normalize_plugin_tool_attrs(attrs) when is_map(attrs) do
    attrs =
      Map.new(attrs, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        {key, value} -> {to_string(key), value}
      end)

    case {Map.get(attrs, "from"), Map.get(attrs, "module")} do
      {nil, module_name} when is_binary(module_name) ->
        Map.put(attrs, "from", "module:" <> module_name)

      _ ->
        attrs
    end
  end

  defp project_tools(tools, opts) when is_map(tools) and is_list(opts) do
    enabled_plugin_names = MapSet.new(plugin_tool_names(opts))
    plugin_tools = plugin_tools_map(opts)

    tools
    |> Map.merge(plugin_tools, fn _name, existing, _plugin -> existing end)
    |> Map.reject(fn {name, entry} ->
      plugin_entry_hidden?(name, entry, enabled_plugin_names, opts)
    end)
  end

  defp project_tools(tools, _opts), do: tools

  defp plugin_entry?(%{"entry_type" => "plugin_module"}), do: true
  defp plugin_entry?(%{"entry_type" => "plugin_mcp"}), do: true
  defp plugin_entry?(_entry), do: false

  defp plugin_tools_map(opts) do
    opts
    |> plugin_tool_entries()
    |> Enum.reduce(%{}, fn entry, acc ->
      case plugin_entry_name(entry) do
        name when is_binary(name) and name != "" -> Map.put(acc, name, entry)
        _ -> acc
      end
    end)
  end

  defp plugin_entry_hidden?(name, entry, enabled_plugin_names, opts) do
    cond do
      not plugin_entry?(entry) ->
        false

      not MapSet.member?(enabled_plugin_names, name) ->
        true

      is_nil(tool_definition(entry, opts)) ->
        true

      mcp_plugin_entry?(entry) and not plugin_mcp_entry_active?(entry, opts) ->
        true

      true ->
        false
    end
  end

  defp mcp_plugin_entry?(%{"entry_type" => "plugin_mcp"}), do: true
  defp mcp_plugin_entry?(_entry), do: false

  defp plugin_mcp_entry_active?(
         %{"plugin_id" => plugin_id, "attrs" => %{"from" => "mcp:" <> spec}},
         opts
       ) do
    case String.split(spec, "/", parts: 2) do
      [server_name, _tool_name] ->
        server_id = MCPServerManager.plugin_server_id(plugin_id, server_name)
        server_id in active_mcp_servers(opts)

      _ ->
        false
    end
  end

  defp plugin_mcp_entry_active?(_entry, _opts), do: false

  defp active_mcp_servers(opts) when is_list(opts) do
    opts
    |> Keyword.get(:plugin_data, Keyword.get(opts, :plugins))
    |> case do
      %{active_mcp_servers: active} when is_list(active) -> active
      %{"active_mcp_servers" => active} when is_list(active) -> active
      _ -> []
    end
  end

  defp tool_projection_opts(%{runtime_snapshot: %{plugins: plugins, config: config}}) do
    if plugin_projection_empty?(plugins),
      do: [config: config],
      else: [plugin_data: plugins, config: config]
  end

  defp tool_projection_opts(%{"runtime_snapshot" => %{plugins: plugins, config: config}}) do
    if plugin_projection_empty?(plugins),
      do: [config: config],
      else: [plugin_data: plugins, config: config]
  end

  defp tool_projection_opts(ctx) when is_map(ctx) do
    []
    |> maybe_put_opt(:plugin_data, Map.get(ctx, :plugin_data) || Map.get(ctx, "plugin_data"))
    |> maybe_put_opt(:plugins, Map.get(ctx, :plugins) || Map.get(ctx, "plugins"))
    |> maybe_put_opt(:config, Map.get(ctx, :config) || Map.get(ctx, "config"))
  end

  defp tool_projection_opts(_ctx), do: []

  defp tool_projection_opts_from_describe_opts(opts) when is_list(opts), do: opts
  defp tool_projection_opts_from_describe_opts(_opts), do: []

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, false), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp plugin_projection_empty?(%{contributions: contributions}) when is_map(contributions),
    do: plugin_contributions_empty?(contributions)

  defp plugin_projection_empty?(%{"contributions" => contributions}) when is_map(contributions),
    do: plugin_contributions_empty?(contributions)

  defp plugin_projection_empty?(_plugins), do: true

  defp plugin_contributions_empty?(contributions) do
    Enum.all?(
      ~w(channels providers tools skills commands hooks tasks workspace_files mcp_servers),
      fn kind ->
        Map.get(contributions, kind) in [nil, []] and
          Map.get(contributions, plugin_kind_atom(kind)) in [nil, []]
      end
    )
  end

  defp plugin_kind_atom("channels"), do: :channels
  defp plugin_kind_atom("providers"), do: :providers
  defp plugin_kind_atom("tools"), do: :tools
  defp plugin_kind_atom("skills"), do: :skills
  defp plugin_kind_atom("commands"), do: :commands
  defp plugin_kind_atom("hooks"), do: :hooks
  defp plugin_kind_atom("tasks"), do: :tasks
  defp plugin_kind_atom("workspace_files"), do: :workspace_files
  defp plugin_kind_atom("mcp_servers"), do: :mcp_servers

  defp build_tools do
    %{}
    |> register_modules(@core_tools, "core")
    |> register_modules(discover_project_tool_modules(), "project")
    |> register_modules(discover_custom_tool_modules(), "custom")
  end

  defp plugin_entry_name(%{"attrs" => %{} = attrs}), do: Map.get(attrs, "name")
  defp plugin_entry_name(_entry), do: nil

  defp entry_module(%{"entry_type" => "plugin_module", "module" => module}), do: module
  defp entry_module(module) when is_atom(module), do: module
  defp entry_module(_entry), do: nil

  defp entry_module_display(entry) do
    case entry_module(entry) do
      module when is_atom(module) -> inspect(module)
      nil -> mcp_server_from_entry(entry) && "mcp:" <> mcp_server_from_entry(entry)
    end
  end

  defp entry_description(entry) do
    case tool_definition(entry, []) do
      %{} = definition -> get_def_description(normalize_definition(definition))
      _ -> ""
    end
  end

  defp entry_source_path(entry) do
    case entry_module(entry) do
      module when is_atom(module) -> CodeUpgrade.source_path(module)
      _ -> nil
    end
  end

  defp entry_layers(entry) do
    case entry_module(entry) do
      module when is_atom(module) -> module_layers(module)
      _ -> ["tool"]
    end
  end

  defp entry_plugin_id(%{"plugin_id" => plugin_id}) when is_binary(plugin_id), do: plugin_id
  defp entry_plugin_id(_entry), do: nil

  defp entry_type(%{"entry_type" => entry_type}) when is_binary(entry_type), do: entry_type
  defp entry_type(_entry), do: "module"

  defp module_layers(module) when is_atom(module) do
    if function_exported?(module, :name, 0) do
      case module.name() do
        "soul_update" -> ["soul"]
        "user_update" -> ["user"]
        "hook" -> ["tool"]
        "observe" -> ["tool"]
        "skill_get" -> ["skill"]
        "skill_capture" -> ["skill"]
        "tool_create" -> ["tool"]
        "tool_list" -> ["tool"]
        "tool_delete" -> ["tool"]
        "task" -> ["tool"]
        "knowledge_capture" -> ["tool"]
        "executor_dispatch" -> ["tool"]
        "executor_status" -> ["tool"]
        "reflect" -> ["code"]
        "evolution_candidate" -> ["tool"]
        "self_update" -> ["code"]
        "self_update_commit" -> ["code"]
        _ -> ["tool"]
      end
    else
      ["tool"]
    end
  end

  defp module_layers(_module), do: ["tool"]

  defp execute_tool_entry(
         _name,
         %{"entry_type" => "plugin_module", "module" => module, "plugin_id" => plugin_id} = entry,
         args,
         ctx
       ) do
    module.execute(args, enrich_plugin_ctx(ctx, entry, plugin_id))
  end

  defp execute_tool_entry(
         name,
         %{"entry_type" => "plugin_mcp", "attrs" => %{} = attrs, "plugin_id" => plugin_id} = entry,
         args,
         ctx
       ) do
    case Map.get(attrs, "from", "") do
      "mcp:" <> spec ->
        case String.split(spec, "/", parts: 2) do
          [server_name, tool_name] ->
            server_id = MCPServerManager.plugin_server_id(plugin_id, server_name)

            MCPServerManager.call_tool(
              server_id,
              tool_name,
              args,
              plugin_ctx_metadata(enrich_plugin_ctx(ctx, entry, plugin_id))
            )

          _ ->
            {:error, "Invalid MCP tool source for #{name}"}
        end

      _ ->
        {:error, "Invalid MCP tool source for #{name}"}
    end
  end

  defp execute_tool_entry(_name, module, args, ctx) when is_atom(module),
    do: module.execute(args, ctx)

  defp enrich_plugin_ctx(ctx, entry, plugin_id) do
    ctx
    |> Map.put(:plugin_id, plugin_id)
    |> Map.put(:plugin_contribution_id, Map.get(entry, "id"))
    |> Map.put(:mcp_server, mcp_server_from_entry(entry))
  end

  defp plugin_ctx_metadata(ctx) do
    %{
      workspace: Map.get(ctx, :workspace) || Map.get(ctx, "workspace") || File.cwd!(),
      config:
        Map.get(ctx, :config) || Map.get(ctx, "config") ||
          runtime_snapshot_config(
            Map.get(ctx, :runtime_snapshot) || Map.get(ctx, "runtime_snapshot")
          ),
      session_key: Map.get(ctx, :session_key) || Map.get(ctx, "session_key") || "default",
      channel: Map.get(ctx, :channel) || Map.get(ctx, "channel"),
      chat_id: Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id"),
      actor: Map.get(ctx, :actor) || Map.get(ctx, "actor"),
      plugin_id: Map.get(ctx, :plugin_id),
      contribution_id: Map.get(ctx, :plugin_contribution_id),
      mcp_server: Map.get(ctx, :mcp_server)
    }
  end

  defp mcp_server_from_entry(%{"attrs" => %{"from" => "mcp:" <> spec}}) do
    spec |> String.split("/", parts: 2) |> List.first()
  end

  defp mcp_server_from_entry(_entry), do: nil

  defp runtime_snapshot_config(%{config: config}), do: config
  defp runtime_snapshot_config(%{"config" => config}), do: config
  defp runtime_snapshot_config(_snapshot), do: nil

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

  defp definition_priority(_name), do: 100

  defp filter_tools(tools, :all, _opts), do: tools

  defp filter_tools(tools, :follow_up, opts) do
    Enum.filter(tools, fn {name, entry} ->
      entry
      |> tool_definition(opts)
      |> normalize_definition()
      |> FollowUp.allowed_tool_definition?() and
        tool_surface?(name, entry, :follow_up, opts)
    end)
  end

  defp filter_tools(tools, :task, opts),
    do: Enum.filter(tools, fn {name, entry} -> tool_surface?(name, entry, :task, opts) end)

  defp filter_tools(tools, :base, opts) do
    Enum.filter(tools, fn {name, entry} ->
      tool_surface?(name, entry, :base, opts)
    end)
  end

  defp filter_tools(tools, :subagent, opts),
    do: Enum.filter(tools, fn {name, entry} -> tool_surface?(name, entry, :subagent, opts) end)

  defp filter_tools(tools, _filter, _opts), do: tools

  defp tool_surface?(name, module, surface, opts) do
    surface = normalize_surface(surface)

    name
    |> tool_surfaces(module, opts)
    |> Enum.member?(surface)
  end

  defp tool_surfaces(name, module, opts) do
    case entry_tool_surfaces(module) || plugin_tool_surfaces(name, opts) do
      [] -> module_tool_surfaces(module)
      surfaces -> surfaces
    end
  end

  defp entry_tool_surfaces(%{"attrs" => %{} = attrs}) do
    attrs
    |> Map.get("surfaces", [])
    |> normalize_surfaces()
  end

  defp entry_tool_surfaces(_entry), do: nil

  defp plugin_tool_surfaces(name, opts) do
    opts
    |> plugin_tool_contributions()
    |> Enum.find_value([], fn
      %{"id" => ^name, "attrs" => %{} = attrs} ->
        attrs
        |> Map.get("surfaces", [])
        |> normalize_surfaces()

      _contribution ->
        nil
    end)
  end

  defp module_tool_surfaces(module) do
    cond do
      is_map(module) ->
        [:all]

      function_exported?(module, :surfaces, 0) ->
        module.surfaces()
        |> normalize_surfaces()
        |> ensure_all_surface()

      function_exported?(module, :category, 0) and module.category() == :base ->
        [:all, :base]

      true ->
        [:all]
    end
  end

  defp normalize_surfaces(surfaces) when is_list(surfaces) do
    surfaces
    |> Enum.map(&normalize_surface/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_surfaces(_surfaces), do: []

  defp ensure_all_surface([]), do: [:all]
  defp ensure_all_surface(surfaces), do: Enum.uniq([:all | surfaces])

  defp normalize_surface(surface) when surface in [:all, :base, :follow_up, :subagent, :task],
    do: surface

  defp normalize_surface(surface) when is_binary(surface) do
    case String.replace(surface, "-", "_") do
      "all" -> :all
      "base" -> :base
      "follow_up" -> :follow_up
      "subagent" -> :subagent
      "task" -> :task
      _ -> nil
    end
  end

  defp normalize_surface(_surface), do: nil

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

  defp error_summary(reason) when is_binary(reason), do: String.slice(reason, 0, 1000)

  defp error_summary(reason),
    do: reason |> inspect(limit: 20, printable_limit: 1000) |> String.slice(0, 1000)

  defp args_summary(args) do
    args
    |> Redactor.redact()
    |> inspect(limit: 20, printable_limit: 1000)
    |> String.slice(0, 1000)
  end
end
