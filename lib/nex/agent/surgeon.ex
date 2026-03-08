defmodule Nex.Agent.Surgeon do
  @moduledoc """
  Code surgeon — safe hot-reload orchestrator for agent modules.

  Upgrades module code at runtime via Evolution. All successful upgrades
  are persisted via git commit + async push. Manual rollback available via
  `Evolution.rollback/1`.
  """

  use GenServer
  require Logger

  alias Nex.Agent.{Evolution, Tool.Registry}

  @core_modules [
    Nex.Agent.Runner,
    Nex.Agent.Session,
    Nex.Agent.ContextBuilder,
    Nex.Agent.InboundWorker,
    Nex.Agent.Subagent,
    Nex.Agent.Gateway
  ]

  defstruct []

  @type t :: %__MODULE__{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Upgrade a module with new code.

  Returns `{:ok, version}` or `{:error, reason}`.
  """
  @spec upgrade(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def upgrade(module, code, opts \\ []) do
    GenServer.call(__MODULE__, {:upgrade, module, code, opts}, 30_000)
  end

  @doc """
  Check if a module is a core module.
  """
  @spec core_module?(atom()) :: boolean()
  def core_module?(module), do: module in @core_modules

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:upgrade, module, code, opts}, _from, state) do
    result = surgery(module, code, opts)
    {:reply, result, state}
  end

  # --- Private ---

  defp surgery(module, code, opts) do
    reason = Keyword.get(opts, :reason, "upgrade")

    case Evolution.upgrade_module(module, code, validate: true) do
      {:ok, version} ->
        maybe_hot_swap_registry(module)
        source_path = get_source_path(module)
        persist_evolution(module, source_path, reason)
        {:ok, version}

      {:error, error} ->
        {:error, error}
    end
  end

  defp persist_evolution(module, source_path, reason) do
    Task.Supervisor.start_child(Nex.Agent.TaskSupervisor, fn ->
      module_short =
        module
        |> to_string()
        |> String.replace_prefix("Elixir.Nex.Agent.", "")

      msg = "evolve(#{module_short}): #{reason}"

      case System.cmd("git", ["add", source_path], stderr_to_stdout: true) do
        {_, 0} ->
          case System.cmd("git", ["commit", "-m", msg], stderr_to_stdout: true) do
            {_, 0} ->
              Task.start(fn ->
                System.cmd("git", ["push"], stderr_to_stdout: true)
              end)

              Logger.info("[Surgeon] Committed evolution: #{msg}")

            {output, _} ->
              Logger.debug("[Surgeon] Git commit skipped: #{String.trim(output)}")
          end

        {output, _} ->
          Logger.warning("[Surgeon] Git add failed: #{String.trim(output)}")
      end
    end)
  end

  defp get_source_path(module) do
    Evolution.source_path(module)
  end

  defp maybe_hot_swap_registry(module) do
    if Process.whereis(Registry) do
      Code.ensure_loaded(module)

      if function_exported?(module, :name, 0) do
        tool_name = module.name()

        if Registry.get(tool_name) do
          Registry.hot_swap(tool_name, module)
        else
          Logger.info("[Surgeon] Registering new tool: #{tool_name}")
          Registry.register(module)
        end
      end
    end
  end
end
