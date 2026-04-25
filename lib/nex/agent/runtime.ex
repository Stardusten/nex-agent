defmodule Nex.Agent.Runtime do
  @moduledoc """
  Single source of truth for the current runtime snapshot.
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Config, ContextBuilder, Skills, Workspace}
  alias Nex.Agent.Command.Catalog, as: CommandCatalog
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Subagent.Profiles, as: SubagentProfiles
  alias Nex.Agent.Tool.Registry, as: ToolRegistry

  defstruct [
    :snapshot,
    :config_loader,
    :prompt_builder,
    :tool_definitions_builder,
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
      skills_builder: Keyword.get(opts, :skills_builder, &Skills.always_instructions/1)
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
         {:ok, command_definitions} <- call_builder(command_builder(opts), []),
         subagent_profiles = SubagentProfiles.load(config, workspace: workspace),
         {:ok, prompt, diagnostics} <-
           call_prompt_builder(prompt_builder(opts, state), [
             Keyword.put(opts, :workspace, workspace)
           ]),
         {:ok, definitions_all} <-
           call_tool_definitions_builder(
             tool_definitions_builder(opts, state),
             :all,
             tool_definition_opts(config, workspace, :all, subagent_profiles)
           ),
         {:ok, definitions_follow_up} <-
           call_tool_definitions_builder(
             tool_definitions_builder(opts, state),
             :follow_up,
             tool_definition_opts(config, workspace, :follow_up, subagent_profiles)
           ),
         {:ok, definitions_subagent} <-
           call_tool_definitions_builder(
             tool_definitions_builder(opts, state),
             :subagent,
             tool_definition_opts(config, workspace, :subagent, subagent_profiles)
           ),
         {:ok, definitions_cron} <-
           call_tool_definitions_builder(
             tool_definitions_builder(opts, state),
             :cron,
             tool_definition_opts(config, workspace, :cron, subagent_profiles)
           ),
         {:ok, always_instructions} <-
           call_builder(skills_builder(opts, state), [Keyword.put(opts, :workspace, workspace)]) do
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

      skills_data = %{
        always_instructions: always_instructions,
        hash: hash(always_instructions)
      }

      {:ok,
       %Snapshot{
         version: version,
         config: config,
         workspace: workspace,
         channels: Config.channels_runtime(config),
         commands: commands_data,
         prompt: prompt_data,
         tools: tools_data,
         subagents: subagents_data,
         skills: skills_data,
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

  defp tool_definition_opts(config, workspace, surface, subagent_profiles) do
    [
      config: config,
      workspace: workspace,
      surface: surface,
      subagent_profiles: subagent_profiles,
      model_runtime: Config.default_model_runtime(config)
    ]
  end

  defp config_loader(opts, state), do: Keyword.get(opts, :config_loader, state.config_loader)
  defp prompt_builder(opts, state), do: Keyword.get(opts, :prompt_builder, state.prompt_builder)

  defp tool_definitions_builder(opts, state),
    do: Keyword.get(opts, :tool_definitions_builder, state.tool_definitions_builder)

  defp skills_builder(opts, state), do: Keyword.get(opts, :skills_builder, state.skills_builder)

  defp command_builder(opts),
    do: Keyword.get(opts, :command_builder, &CommandCatalog.runtime_definitions/0)

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
