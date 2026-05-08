defmodule Nex.Agent.Interface.MCP.Transport.Stdio do
  @moduledoc """
  Stdio transport adapter for MCP clients.

  This module owns the sandboxed long-running process and newline-delimited
  JSON framing. It does not know MCP method names or request ids beyond
  decoding complete JSON-RPC messages and forwarding them to the client owner.
  """

  use GenServer
  require Logger

  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Sandbox.{Command, Exec, Policy}
  alias Nex.Agent.Sandbox.Process, as: SandboxProcess

  @behaviour Nex.Agent.Interface.MCP.Transport

  @default_timeout_ms 30_000

  defstruct [:owner, :sandbox_process, :port, buffer: ""]

  @impl true
  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  @spec send_request(pid(), map()) :: :ok | {:error, term()}
  def send_request(pid, request) do
    GenServer.call(pid, {:send_request, request})
  end

  @impl true
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    with {:ok, owner} <- fetch_owner(opts),
         {:ok, command} <- fetch_command(opts),
         {:ok, process} <- open_process(opts, command) do
      {:ok,
       %__MODULE__{
         owner: owner,
         sandbox_process: process,
         port: process.port,
         buffer: ""
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_request, request}, _from, state) do
    {:reply, Exec.write(state.sandbox_process, Jason.encode!(request) <> "\n"), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data
    {lines, remaining} = split_lines(buffer)
    state = %{state | buffer: remaining}

    state =
      Enum.reduce(lines, state, fn line, acc ->
        line = String.trim(line)

        if line == "" do
          acc
        else
          forward_decoded_response(line, acc)
        end
      end)

    {:noreply, state}
  end

  def handle_info({port, :eof}, %{port: port} = state) do
    send(state.owner, {:mcp_transport_closed, self(), :eof})
    {:stop, :normal, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:mcp_transport_closed, self(), {:exit_status, status}})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.sandbox_process do
      Exec.close(state.sandbox_process)
    end

    :ok
  end

  defp fetch_owner(opts) do
    case get_opt(opts, :owner) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :owner_required}
    end
  end

  defp fetch_command(opts) do
    case get_opt(opts, :command) do
      command when is_binary(command) and command != "" -> {:ok, command}
      _ -> {:error, :command_required}
    end
  end

  defp open_process(opts, command) do
    cwd = get_opt(opts, :cwd, File.cwd!())
    workspace = get_opt(opts, :workspace, cwd)
    timeout_ms = get_opt(opts, :timeout_ms, @default_timeout_ms)

    command = %Command{
      program: command,
      args: opts |> get_opt(:args, []) |> normalize_args(),
      cwd: cwd,
      env: opts |> get_opt(:env, %{}) |> normalize_env(),
      timeout_ms: timeout_ms,
      metadata: %{
        workspace: workspace,
        observe_context: %{workspace: workspace},
        observe_attrs: %{"interface" => "mcp", "mcp_transport" => "stdio"}
      }
    }

    case Exec.open(command, sandbox_policy(opts, cwd)) do
      {:ok, %SandboxProcess{} = process} -> {:ok, process}
      {:error, reason} -> {:error, reason}
    end
  end

  defp forward_decoded_response(line, state) do
    case Jason.decode(line) do
      {:ok, response} ->
        send(state.owner, {:mcp_transport_response, self(), response})
        state

      {:error, reason} ->
        Logger.warning("Failed to parse MCP stdio response: #{inspect(reason)}")
        state
    end
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n", parts: :infinity) do
      [] ->
        {[], ""}

      parts ->
        {complete, [remaining]} = Enum.split(parts, -1)
        {complete, remaining}
    end
  end

  defp sandbox_policy(opts, cwd) do
    case get_opt(opts, :runtime_snapshot) do
      %{sandbox: %Policy{} = policy} ->
        policy

      _ ->
        opts
        |> get_opt(:config)
        |> Config.sandbox_runtime(workspace: get_opt(opts, :workspace, cwd))
    end
  end

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env(env) when is_list(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env(_env), do: %{}

  defp normalize_args(args) when is_list(args), do: Enum.map(args, &to_string/1)
  defp normalize_args(_args), do: []

  defp get_opt(opts, key, default \\ nil)

  defp get_opt(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp get_opt(opts, key, default) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp get_opt(_opts, _key, default), do: default
end
