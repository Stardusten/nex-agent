defmodule Nex.Agent.Interface.MCP.ServerManager do
  @moduledoc """
  MCP server lifecycle manager.
  """

  use GenServer
  require Logger

  alias Nex.Agent.Interface.MCP
  alias Nex.Agent.Runtime
  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Sandbox.{Approval, PermissionRule}
  alias Nex.Agent.Sandbox.Approval.Request

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{servers: %{}, registry: nil}, opts ++ [name: @name])
  end

  @spec start(String.t(), keyword() | map(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def start(name, config, opts \\ []) do
    GenServer.call(@name, {:start, name, config, opts})
  end

  @spec stop(String.t()) :: :ok | {:error, String.t()}
  def stop(server_id) do
    GenServer.call(@name, {:stop, server_id})
  end

  @spec call_tool(String.t(), String.t(), map(), keyword() | map()) ::
          {:ok, map()} | {:error, String.t()}
  def call_tool(server_id, tool_name, arguments, opts \\ []) do
    GenServer.call(@name, {:call_tool, server_id, tool_name, arguments, opts}, 60_000)
  end

  @spec list() :: [map()]
  def list do
    GenServer.call(@name, :list)
  end

  @spec get_by_name(String.t()) :: {:ok, String.t()} | :error
  def get_by_name(name) do
    GenServer.call(@name, {:get_by_name, name})
  end

  @spec start_configured() :: {:ok, [String.t()]} | {:error, String.t()}
  def start_configured do
    GenServer.call(@name, :start_configured)
  end

  @spec start_and_register(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def start_and_register(registry) do
    GenServer.call(@name, {:start_and_register, registry})
  end

  @spec register_tools(String.t()) :: :ok | {:error, String.t()}
  def register_tools(server_id) do
    GenServer.call(@name, {:register_tools, server_id})
  end

  @spec reconcile(map(), keyword()) :: :ok | {:error, term()}
  def reconcile(plugin_data, opts \\ []) do
    GenServer.call(@name, {:reconcile, plugin_data, opts}, :infinity)
  end

  @spec plugin_server_id(String.t(), String.t()) :: String.t()
  def plugin_server_id(plugin_id, server_name), do: "plugin:" <> plugin_id <> ":" <> server_name

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:start, name, config, opts}, _from, state) do
    case start_server(state, name, config, opts) do
      {:ok, server_id, next_state} -> {:reply, {:ok, server_id}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:stop, server_id}, _from, state) do
    case stop_server(state, server_id) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:call_tool, server_id, tool_name, arguments, opts}, _from, state) do
    case Map.get(state.servers, server_id) do
      nil ->
        {:reply, {:error, "Server not found"}, state}

      server ->
        with :ok <- authorize_call(server, tool_name, opts) do
          timeout = (server.tool_timeout || 30) * 1000
          {:reply, MCP.call_tool(server.pid, tool_name, arguments, timeout), state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:list, _from, state) do
    servers =
      Enum.map(state.servers, fn {id, server} ->
        %{
          id: id,
          name: server.name,
          config: server.config,
          tool_timeout: server.tool_timeout,
          tools_count: length(server.tools),
          origin: server.origin,
          plugin_id: server.plugin_id,
          contribution_id: server.contribution_id
        }
      end)

    {:reply, servers, state}
  end

  def handle_call({:get_by_name, name}, _from, state) do
    result =
      Enum.find_value(state.servers, :error, fn {id, server} ->
        if server.name == name, do: {:ok, id}
      end)

    {:reply, result, state}
  end

  def handle_call(:start_configured, _from, state) do
    {:ok, server_ids, state} = start_configured_servers(state)
    {:reply, {:ok, server_ids}, state}
  end

  def handle_call({:start_and_register, registry}, _from, state) do
    {:ok, server_ids, state} = start_configured_servers(state)
    state = %{state | registry: registry}
    Enum.each(server_ids, &register_tools_to_registry(&1, state, registry))
    {:reply, {:ok, server_ids}, state}
  end

  def handle_call({:register_tools, server_id}, _from, state) do
    case Map.get(state.servers, server_id) do
      nil ->
        {:reply, {:error, "Server not found"}, state}

      server ->
        case MCP.list_tools(server.pid) do
          {:ok, %{"tools" => tools}} ->
            {:reply, {:ok, length(tools)}, put_in(state, [:servers, server_id, :tools], tools)}

          {:ok, tools} when is_list(tools) ->
            {:reply, {:ok, length(tools)}, put_in(state, [:servers, server_id, :tools], tools)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:reconcile, plugin_data, opts}, _from, state) do
    desired = desired_plugin_servers(plugin_data)

    state =
      state
      |> stop_removed_plugin_servers(desired)
      |> start_missing_plugin_servers(desired, opts)

    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.servers, fn {_id, server} -> MCP.stop(server.pid) end)
    :ok
  end

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(config) when is_list(config), do: config
  defp normalize_config(_config), do: []

  defp start_configured_servers(state) do
    configured = Application.get_env(:nex_agent, :mcp_servers, %{})

    {server_ids, state} =
      Enum.reduce(configured, {[], state}, fn {name, config}, {server_ids, acc_state} ->
        case start_server(acc_state, to_string(name), config, []) do
          {:ok, server_id, next_state} ->
            {[server_id | server_ids], next_state}

          {:error, reason, next_state} ->
            Logger.warning("[MCP] Failed to start configured server #{inspect(name)}: #{reason}")
            {server_ids, next_state}
        end
      end)

    {:ok, Enum.reverse(server_ids), state}
  end

  defp start_server(state, name, config, opts) do
    server_id =
      Keyword.get(opts, :server_id) ||
        "#{name}-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

    normalized = normalize_config(config)

    case MCP.start_link(normalized) do
      {:ok, pid} ->
        case MCP.initialize(pid) do
          :ok ->
            server = %{
              pid: pid,
              name: name,
              config: redacted_server_config(normalized),
              tool_timeout: config_value(normalized, :tool_timeout, 30),
              tools: [],
              origin: Keyword.get(opts, :origin, :manual),
              plugin_id: Keyword.get(opts, :plugin_id),
              contribution_id: Keyword.get(opts, :contribution_id)
            }

            {:ok, server_id, put_in(state, [:servers, server_id], server)}

          {:error, reason} ->
            MCP.stop(pid)
            {:error, "Failed to initialize: #{inspect(reason)}", state}
        end

      {:error, reason} ->
        {:error, "Failed to start: #{inspect(reason)}", state}
    end
  end

  defp stop_server(state, server_id) do
    case Map.pop(state.servers, server_id) do
      {nil, _servers} ->
        {:error, "Server not found", state}

      {server, servers} ->
        MCP.stop(server.pid)
        {:ok, %{state | servers: servers}}
    end
  end

  defp register_tools_to_registry(server_id, state, registry) do
    case {Map.get(state.servers, server_id), registry} do
      {%{pid: pid, name: name}, _registry} ->
        case MCP.list_tools(pid) do
          {:ok, %{"tools" => tools}} ->
            Logger.info("[MCP] Would register #{length(tools)} tools from #{name}")
            :ok

          {:ok, tools} when is_list(tools) ->
            Logger.info("[MCP] Would register #{length(tools)} tools from #{name}")
            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp desired_plugin_servers(plugin_data) do
    contributions =
      Map.get(plugin_data, :contributions) || Map.get(plugin_data, "contributions") || %{}

    Map.get(contributions, :mcp_servers) || Map.get(contributions, "mcp_servers") || []
  end

  defp stop_removed_plugin_servers(state, desired) do
    desired_ids =
      desired
      |> Enum.map(fn entry -> plugin_server_id(entry["plugin_id"], entry["id"]) end)
      |> MapSet.new()

    Enum.reduce(state.servers, state, fn {server_id, server}, acc ->
      if server.origin == :plugin and not MapSet.member?(desired_ids, server_id) do
        MCP.stop(server.pid)
        %{acc | servers: Map.delete(acc.servers, server_id)}
      else
        acc
      end
    end)
  end

  defp start_missing_plugin_servers(state, desired, opts) do
    runtime_ctx = reconcile_runtime_context(opts)

    Enum.reduce(desired, state, fn entry, acc ->
      runtime_id = plugin_server_id(entry["plugin_id"], entry["id"])

      cond do
        Map.has_key?(acc.servers, runtime_id) ->
          acc

        true ->
          case authorize_connect(entry, runtime_ctx.workspace, runtime_ctx.config) do
            :ok ->
              attrs = Map.fetch!(entry, "attrs")

              start_config =
                attrs
                |> Map.put_new("workspace", runtime_ctx.workspace)
                |> Map.put_new("cwd", runtime_ctx.workspace)
                |> Map.put("config", runtime_ctx.config)
                |> Map.put("plugin_id", entry["plugin_id"])
                |> Map.put("contribution_id", entry["id"])
                |> Map.put("plugin_config", plugin_config(runtime_ctx.config, entry["plugin_id"]))

              case start_server(
                     acc,
                     entry["id"],
                     start_config,
                     server_id: runtime_id,
                     origin: :plugin,
                     plugin_id: entry["plugin_id"],
                     contribution_id: entry["id"]
                   ) do
                {:ok, _runtime_id, next_state} ->
                  next_state

                {:error, reason, next_state} ->
                  Logger.warning(
                    "[MCP] Failed to start plugin MCP server #{runtime_id}: #{inspect(reason)}"
                  )

                  next_state
              end

            {:error, reason} ->
              Logger.warning("[MCP] Plugin MCP server #{runtime_id} not started: #{reason}")
              acc
          end
      end
    end)
  end

  defp authorize_connect(
         %{"plugin_id" => plugin_id, "id" => contribution_id, "attrs" => %{}},
         workspace,
         config
       ) do
    session_key = "plugin:" <> plugin_id
    raw_event = mcp_raw_event("connect", plugin_id, contribution_id, nil, workspace, [])
    decision_opts = [extra_rules: config_default_mcp_rules(config, workspace)]

    case Approval.debug_decision(workspace, session_key, raw_event, decision_opts) do
      %{action: :allow} ->
        :ok

      %{action: :deny} ->
        {:error, "approval denied for plugin MCP connect"}

      _ ->
        {:error, "approval required for plugin MCP connect"}
    end
  end

  defp authorize_call(
         %{origin: :plugin, plugin_id: plugin_id, contribution_id: contribution_id},
         tool_name,
         opts
       ) do
    runtime_context = reconcile_runtime_context(opts)
    workspace = opt_value(opts, :workspace, runtime_context.workspace)
    session_key = opt_value(opts, :session_key, "plugin:" <> plugin_id)
    raw_event = mcp_raw_event("call", plugin_id, contribution_id, tool_name, workspace, opts)

    decision_opts = [
      extra_rules:
        config_default_mcp_rules(opt_value(opts, :config, runtime_context.config), workspace)
    ]

    case Approval.debug_decision(workspace, session_key, raw_event, decision_opts) do
      %{action: :allow} ->
        :ok

      %{action: :deny} ->
        {:error, "approval denied for plugin MCP tool call"}

      _ ->
        if interactive_opts?(opts) do
          request =
            Request.new(%{
              kind: :mcp,
              operation: :call,
              subject: contribution_id <> "/" <> tool_name,
              workspace: workspace,
              session_key: session_key,
              channel: opt_value(opts, :channel),
              chat_id: opt_value(opts, :chat_id),
              description:
                "Allow plugin MCP tool call #{tool_name} for #{plugin_id}/#{contribution_id}",
              grant_key: first_grant_key(raw_event),
              grant_options: PermissionRule.grant_options(raw_event),
              authorized_actor: actor_from_opts(opts),
              metadata: %{"permission_event" => PermissionRule.raw_event_to_map(raw_event)}
            })

          case Approval.request(request, publish?: false) do
            {:ok, :approved} ->
              :ok

            {:error, :denied} ->
              {:error, "approval denied for plugin MCP tool call"}

            {:error, reason} ->
              {:error, "approval failed for plugin MCP tool call: #{inspect(reason)}"}
          end
        else
          {:error, "approval required for plugin MCP tool call"}
        end
    end
  end

  defp authorize_call(_server, _tool_name, _opts), do: :ok

  defp mcp_raw_event(action, plugin_id, contribution_id, tool_name, workspace, opts) do
    tool_event_name =
      case {action, tool_name} do
        {"connect", _} -> "mcp:connect:#{plugin_id}:#{contribution_id}"
        {"call", name} -> "mcp:call:#{plugin_id}:#{contribution_id}:#{name}"
      end

    %{
      tool_name: tool_event_name,
      workspace: workspace,
      channel: opt_value(opts, :channel),
      chat_id: opt_value(opts, :chat_id),
      actor: actor_from_opts(opts),
      metadata: %{
        "plugin_id" => plugin_id,
        "mcp_server" => contribution_id,
        "mcp_tool" => tool_name,
        "mcp_operation" => action
      }
    }
  end

  defp actor_from_opts(opts) do
    case opt_value(opts, :actor) do
      %{} = actor -> actor
      value when is_binary(value) -> %{"id" => value}
      _ -> %{"kind" => "system", "id" => "plugin-mcp"}
    end
  end

  defp first_grant_key(raw_event) do
    raw_event
    |> PermissionRule.grant_options()
    |> List.first(%{})
    |> Map.get("grant_key", "")
  end

  defp interactive_opts?(opts) do
    present?(opt_value(opts, :channel)) and present?(opt_value(opts, :chat_id))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp reconcile_runtime_context(opts) do
    workspace = opt_value(opts, :workspace)
    config = opt_value(opts, :config)

    cond do
      is_binary(workspace) ->
        %{workspace: workspace, config: config}

      true ->
        case Runtime.current() do
          {:ok, %{workspace: current_workspace, config: current_config}} ->
            %{workspace: current_workspace, config: current_config}

          _ ->
            %{workspace: File.cwd!(), config: nil}
        end
    end
  end

  defp config_default_mcp_rules(%Config{} = config, workspace) do
    raw = Config.sandbox_runtime(config, workspace: workspace).raw || %{}
    approval = Map.get(raw, "approval") || Map.get(raw, :approval) || %{}
    default = Map.get(approval, "default") || Map.get(approval, :default)

    case default do
      "allow" ->
        [
          %{
            id: "config_default_allow_mcp",
            level: 0,
            effect: :allow,
            scope: :workspace,
            source: :workspace_config,
            predicates: [{:resource_eq, :mcp}]
          }
        ]

      _ ->
        []
    end
  end

  defp config_default_mcp_rules(_config, _workspace), do: []

  defp plugin_config(%Config{} = config, plugin_id) when is_binary(plugin_id) do
    config
    |> Config.plugins_runtime()
    |> opt_value(:config, %{})
    |> opt_value(plugin_id, %{})
  end

  defp plugin_config(_config, _plugin_id), do: %{}

  defp config_value(config, key, default) when is_list(config) do
    Keyword.get(config, key, default)
  end

  defp config_value(config, key, default) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end

  defp config_value(_config, _key, default), do: default

  defp redacted_server_config(config) when is_list(config) do
    Enum.map(config, fn
      {key, value} -> {key, redacted_server_config_value(key, value)}
      value -> value
    end)
  end

  defp redacted_server_config(%{} = config) do
    Map.new(config, fn {key, value} ->
      {key, redacted_server_config_value(key, value)}
    end)
    |> Map.drop(["config", :config, "runtime_snapshot", :runtime_snapshot, "secrets", :secrets])
  end

  defp redacted_server_config(config), do: config

  defp redacted_server_config_value(key, value) when key in ["env", :env, "headers", :headers] do
    redact_value_table(value)
  end

  defp redacted_server_config_value(key, _value)
       when key in ["config", :config, "runtime_snapshot", :runtime_snapshot, "secrets", :secrets],
       do: "[REDACTED]"

  defp redacted_server_config_value(_key, %{} = value), do: redacted_server_config(value)

  defp redacted_server_config_value(_key, value) when is_list(value),
    do: redacted_server_config(value)

  defp redacted_server_config_value(_key, value), do: value

  defp redact_value_table(value) when is_map(value) do
    Map.new(value, fn {key, _value} -> {key, "[REDACTED]"} end)
  end

  defp redact_value_table(value) when is_list(value) do
    Enum.map(value, fn
      {key, _value} -> {key, "[REDACTED]"}
      [key, _value] -> [key, "[REDACTED]"]
      other -> other
    end)
  end

  defp redact_value_table(_value), do: "[REDACTED]"

  defp opt_value(opts, key, default \\ nil)

  defp opt_value(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp opt_value(opts, key, default) when is_map(opts) do
    fallback_key = if is_atom(key), do: Atom.to_string(key), else: key
    Map.get(opts, key, Map.get(opts, fallback_key, default))
  end

  defp opt_value(_opts, _key, default), do: default
end
