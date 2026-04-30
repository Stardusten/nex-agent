defmodule Nex.Agent.Runtime do
  @moduledoc """
  Single source of truth for the current runtime snapshot.
  """

  use GenServer
  require Logger

  alias Nex.Agent.{
    Runtime.Config,
    Turn.ContextBuilder,
    Capability.Hooks,
    Extension.Plugin,
    Capability.Skills,
    Runtime.Workspace
  }

  alias Nex.Agent.Conversation.Command.Catalog, as: CommandCatalog
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Capability.Subagent.Profiles, as: SubagentProfiles
  alias Nex.Agent.Capability.Tool.Registry, as: ToolRegistry
  alias Nex.Agent.Interface.Workbench.AppManifest
  alias Nex.Agent.Interface.Workbench.Store, as: WorkbenchStore

  defstruct [
    :snapshot,
    :config_loader,
    :prompt_builder,
    :tool_definitions_builder,
    :hooks_builder,
    :plugins_builder,
    :skills_builder,
    subscribers: %{}
  ]

  @type reload_result :: {:ok, Snapshot.t()} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec current() :: {:ok, Snapshot.t()} | {:error, :runtime_unavailable}
  def current do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :runtime_unavailable}
      _pid -> GenServer.call(__MODULE__, :current)
    end
  end

  @spec current_version() :: pos_integer() | nil
  def current_version do
    case current() do
      {:ok, %Snapshot{version: version}} -> version
      {:error, :runtime_unavailable} -> nil
    end
  end

  @spec reload(keyword()) :: reload_result()
  def reload(opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :runtime_unavailable}
      _pid -> GenServer.call(__MODULE__, {:reload, opts}, :infinity)
    end
  end

  @spec subscribe() :: :ok | {:error, :runtime_unavailable}
  def subscribe do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :runtime_unavailable}
      _pid -> GenServer.call(__MODULE__, {:subscribe, self()})
    end
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      config_loader: Keyword.get(opts, :config_loader, &Config.load/1),
      prompt_builder:
        Keyword.get(opts, :prompt_builder, &ContextBuilder.build_system_prompt_with_diagnostics/1),
      tool_definitions_builder:
        Keyword.get(opts, :tool_definitions_builder, &ToolRegistry.definitions/2),
      hooks_builder: Keyword.get(opts, :hooks_builder, &Hooks.load/1),
      plugins_builder: Keyword.get(opts, :plugins_builder, &Plugin.runtime_data/1),
      skills_builder: Keyword.get(opts, :skills_builder, &Skills.runtime_data/1)
    }

    case build_snapshot(state, opts, 1) do
      {:ok, snapshot} ->
        {:ok, %{state | snapshot: snapshot}}

      {:error, reason} ->
        Logger.error("[Runtime] Initial snapshot build failed: #{inspect(reason)}")
        {:stop, {:snapshot_build_failed, reason}}
    end
  end

  @impl true
  def handle_call(:current, _from, %__MODULE__{snapshot: %Snapshot{} = snapshot} = state) do
    {:reply, {:ok, snapshot}, state}
  end

  def handle_call(:current, _from, state) do
    {:reply, {:error, :runtime_unavailable}, state}
  end

  @impl true
  def handle_call({:reload, opts}, _from, %__MODULE__{} = state) do
    old_snapshot = state.snapshot
    next_version = if old_snapshot, do: old_snapshot.version + 1, else: 1

    case build_snapshot(state, opts, next_version) do
      {:ok, snapshot} ->
        payload = %{
          old_version: if(old_snapshot, do: old_snapshot.version, else: nil),
          new_version: snapshot.version,
          changed_paths: snapshot.changed_paths
        }

        broadcast(state.subscribers, {:runtime_updated, payload})
        {:reply, {:ok, snapshot}, %{state | snapshot: snapshot}}

      {:error, reason} ->
        Logger.warning("[Runtime] Reload failed; keeping previous snapshot: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, pid) do
        ^ref -> Map.delete(state.subscribers, pid)
        _ -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  defp build_snapshot(%__MODULE__{} = state, opts, version) do
    with {:ok, config} <- call_builder(config_loader(opts, state), [opts]),
         {:ok, workspace} <- resolve_workspace(config, opts),
         {:ok, plugins_result} <-
           call_builder(plugins_builder(opts, state), [
             opts
             |> Keyword.put(:workspace, workspace)
             |> Keyword.put(:config, config)
           ]),
         plugins_data = normalize_plugins_data(plugins_result),
         plugins_data = merge_plugin_config_diagnostics(config, plugins_data),
         {:ok, command_definitions} <-
           call_command_builder(command_builder(opts), [
             opts
             |> Keyword.put(:workspace, workspace)
             |> Keyword.put(:config, config)
             |> Keyword.put(:plugin_data, plugins_data)
           ]),
         subagent_profiles = SubagentProfiles.load(config, workspace: workspace),
         {:ok, skills_result} <-
           call_builder(skills_builder(opts, state), [
             opts
             |> Keyword.put(:workspace, workspace)
             |> Keyword.put(:config, config)
             |> Keyword.put(:plugin_data, plugins_data)
           ]),
         skills_data = normalize_skills_data(skills_result),
         {:ok, prompt, diagnostics} <-
           call_prompt_builder(prompt_builder(opts, state), [
             opts
             |> Keyword.put(:workspace, workspace)
             |> Keyword.put(:skill_catalog_prompt, skills_data.catalog_prompt)
           ]),
         {:ok, definitions_all} <-
           call_tool_definitions_builder(
             tool_definitions_builder(opts, state),
             :all,
             tool_definition_opts(config, workspace, :all, subagent_profiles, plugins_data)
           ),
         {:ok, definitions_follow_up} <-
           call_tool_definitions_builder(
             tool_definitions_builder(opts, state),
             :follow_up,
             tool_definition_opts(config, workspace, :follow_up, subagent_profiles, plugins_data)
           ),
         {:ok, definitions_subagent} <-
           call_tool_definitions_builder(
             tool_definitions_builder(opts, state),
             :subagent,
             tool_definition_opts(config, workspace, :subagent, subagent_profiles, plugins_data)
           ),
         {:ok, definitions_cron} <-
           call_tool_definitions_builder(
             tool_definitions_builder(opts, state),
             :cron,
             tool_definition_opts(config, workspace, :cron, subagent_profiles, plugins_data)
           ),
         {:ok, hooks_data} <-
           call_builder(hooks_builder(opts, state), [Keyword.put(opts, :workspace, workspace)]) do
      prompt_data = %{
        system_prompt: prompt,
        diagnostics: diagnostics,
        hash: hash({prompt, diagnostics})
      }

      commands_data = %{
        definitions: command_definitions,
        hash: hash(command_definitions)
      }

      tools_data = %{
        definitions_all: definitions_all,
        definitions_follow_up: definitions_follow_up,
        definitions_subagent: definitions_subagent,
        definitions_cron: definitions_cron,
        hash:
          hash({definitions_all, definitions_follow_up, definitions_subagent, definitions_cron})
      }

      subagent_definitions = SubagentProfiles.definitions(subagent_profiles)

      subagents_data = %{
        profiles: subagent_profiles,
        definitions: subagent_definitions,
        hash: hash(subagent_profiles)
      }

      workbench_data = workbench_data(config, workspace)

      {:ok,
       %Snapshot{
         version: version,
         config_path: Config.config_path(opts),
         config: config,
         workspace: workspace,
         sandbox: Config.sandbox_runtime(config, workspace: workspace),
         channels: Config.channels_runtime(config, plugin_data: plugins_data),
         commands: commands_data,
         prompt: prompt_data,
         tools: tools_data,
         subagents: subagents_data,
         skills: skills_data,
         hooks: hooks_data,
         plugins: plugins_data,
         workbench: workbench_data,
         changed_paths: changed_paths(opts)
       }}
    end
  end

  defp resolve_workspace(%Config{} = config, opts) do
    workspace =
      Keyword.get(opts, :workspace) || Config.configured_workspace(config) || Workspace.root(opts)

    {:ok, workspace}
  rescue
    e -> {:error, {:workspace, e}}
  end

  defp call_prompt_builder(fun, args) do
    case apply(fun, args) do
      {prompt, diagnostics} when is_binary(prompt) and is_list(diagnostics) ->
        {:ok, prompt, diagnostics}

      {:ok, prompt, diagnostics} when is_binary(prompt) and is_list(diagnostics) ->
        {:ok, prompt, diagnostics}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_prompt_builder_result, other}}
    end
  rescue
    e -> {:error, {:prompt_builder, e}}
  catch
    kind, reason -> {:error, {:prompt_builder, {kind, reason}}}
  end

  defp call_builder(fun, args) do
    case apply(fun, args) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      value -> {:ok, value}
    end
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp call_tool_definitions_builder(fun, filter, definition_opts) when is_function(fun, 2) do
    call_builder(fun, [filter, definition_opts])
  end

  defp call_tool_definitions_builder(fun, filter, _definition_opts) when is_function(fun, 1) do
    call_builder(fun, [filter])
  end

  defp call_command_builder(fun, opts) when is_function(fun, 1), do: call_builder(fun, opts)
  defp call_command_builder(fun, _opts) when is_function(fun, 0), do: call_builder(fun, [])

  defp tool_definition_opts(config, workspace, surface, subagent_profiles, plugins_data) do
    [
      config: config,
      workspace: workspace,
      surface: surface,
      subagent_profiles: subagent_profiles,
      plugin_data: plugins_data,
      model_runtime: Config.default_model_runtime(config, plugin_data: plugins_data)
    ]
  end

  defp config_loader(opts, state), do: Keyword.get(opts, :config_loader, state.config_loader)
  defp prompt_builder(opts, state), do: Keyword.get(opts, :prompt_builder, state.prompt_builder)

  defp tool_definitions_builder(opts, state),
    do: Keyword.get(opts, :tool_definitions_builder, state.tool_definitions_builder)

  defp hooks_builder(opts, state), do: Keyword.get(opts, :hooks_builder, state.hooks_builder)

  defp plugins_builder(opts, state),
    do: Keyword.get(opts, :plugins_builder, state.plugins_builder)

  defp skills_builder(opts, state), do: Keyword.get(opts, :skills_builder, state.skills_builder)

  defp command_builder(opts),
    do: Keyword.get(opts, :command_builder, &CommandCatalog.runtime_definitions/1)

  defp normalize_skills_data(%{} = skills) do
    cards = Map.get(skills, :cards) || Map.get(skills, "cards") || []
    catalog_prompt = Map.get(skills, :catalog_prompt) || Map.get(skills, "catalog_prompt") || ""
    diagnostics = Map.get(skills, :diagnostics) || Map.get(skills, "diagnostics") || []

    %{
      cards: cards,
      catalog_prompt: catalog_prompt,
      diagnostics: diagnostics,
      hash:
        Map.get(skills, :hash) || Map.get(skills, "hash") ||
          hash({cards, catalog_prompt, diagnostics})
    }
  end

  defp normalize_skills_data(catalog_prompt) when is_binary(catalog_prompt) do
    %{
      cards: [],
      catalog_prompt: catalog_prompt,
      diagnostics: [],
      hash: hash(catalog_prompt)
    }
  end

  defp normalize_plugins_data(%{} = plugins) do
    manifests = Map.get(plugins, :manifests) || Map.get(plugins, "manifests") || []
    enabled = Map.get(plugins, :enabled) || Map.get(plugins, "enabled") || []
    contributions = normalize_plugin_contributions(plugins)
    diagnostics = Map.get(plugins, :diagnostics) || Map.get(plugins, "diagnostics") || []

    %{
      manifests: manifests,
      enabled: enabled,
      contributions: contributions,
      diagnostics: diagnostics,
      hash:
        Map.get(plugins, :hash) || Map.get(plugins, "hash") ||
          hash({manifests, enabled, contributions, diagnostics})
    }
  end

  defp normalize_plugins_data(_plugins) do
    contributions = empty_plugin_contributions()

    %{
      manifests: [],
      enabled: [],
      contributions: contributions,
      diagnostics: [],
      hash: hash({[], [], contributions, []})
    }
  end

  defp normalize_plugin_contributions(plugins) do
    contributions = Map.get(plugins, :contributions) || Map.get(plugins, "contributions") || %{}

    empty_plugin_contributions()
    |> Enum.into(%{}, fn {kind, []} ->
      {kind, Map.get(contributions, kind) || Map.get(contributions, Atom.to_string(kind)) || []}
    end)
  end

  defp empty_plugin_contributions do
    %{
      channels: [],
      providers: [],
      tools: [],
      skills: [],
      commands: []
    }
  end

  defp merge_plugin_config_diagnostics(%Config{} = config, plugins_data) do
    provider_diagnostics =
      config
      |> Config.provider_diagnostics(plugin_data: plugins_data)
      |> Enum.map(&provider_diagnostic_to_map/1)

    case provider_diagnostics do
      [] ->
        plugins_data

      diagnostics ->
        next_diagnostics = plugins_data.diagnostics ++ diagnostics

        %{
          plugins_data
          | diagnostics: next_diagnostics,
            hash:
              hash(
                {plugins_data.manifests, plugins_data.enabled, plugins_data.contributions,
                 next_diagnostics}
              )
        }
    end
  end

  defp provider_diagnostic_to_map(%{} = diagnostic) do
    Map.new(diagnostic, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
    |> Map.put("kind", "provider")
  end

  defp workbench_data(config, workspace) do
    %{"apps" => apps, "diagnostics" => diagnostics} =
      WorkbenchStore.load_all(workspace: workspace)

    app_maps = Enum.map(apps, &AppManifest.to_map/1)
    runtime = Config.workbench_runtime(config)

    %{
      runtime: runtime,
      apps: app_maps,
      diagnostics: diagnostics,
      hash: hash({runtime, app_maps, diagnostics})
    }
  end

  defp changed_paths(opts) do
    opts
    |> Keyword.get(:changed_paths, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp hash(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
  end

  defp broadcast(subscribers, message) do
    Enum.each(subscribers, fn {pid, _ref} -> send(pid, message) end)
  end
end
