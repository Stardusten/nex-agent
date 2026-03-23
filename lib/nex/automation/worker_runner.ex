defmodule Nex.Automation.WorkerRunner do
  @moduledoc false

  use GenServer

  defstruct [:id, :notify, :port, :timeout_ref, output: ""]

  @type result :: %{
          status: :completed | :failed | :cancelled | :timed_out,
          exit_code: integer() | nil,
          output: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec cancel(pid(), keyword()) :: :ok
  def cancel(pid, _opts \\ []) do
    GenServer.call(pid, :cancel)
  end

  @spec status(pid()) :: map()
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    notify = Keyword.fetch!(opts, :notify)
    command = Keyword.fetch!(opts, :command)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout_ms = Keyword.get(opts, :timeout_ms, 3_600_000)
    env = Keyword.get(opts, :env, %{})

    shell_command = build_shell_command(cwd, command)

    port =
      Port.open({:spawn_executable, to_charlist(shell_path())}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :eof,
        args: [~c"-lc", to_charlist(shell_command)],
        env: env_to_port(env)
      ])

    timeout_ref = Process.send_after(self(), :timeout, timeout_ms)

    {:ok,
     %__MODULE__{
       id: id,
       notify: notify,
       port: port,
       timeout_ref: timeout_ref
     }}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    state
    |> close_port()
    |> finish(%{status: :cancelled, exit_code: nil})

    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{id: state.id, output: state.output}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, %{state | output: state.output <> data}}
  end

  @impl true
  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    status = if exit_code == 0, do: :completed, else: :failed
    finish(state, %{status: status, exit_code: exit_code})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({port, :eof}, %{port: port} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:timeout, state) do
    state
    |> close_port()
    |> finish(%{status: :timed_out, exit_code: nil})

    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    close_port(state)
    :ok
  end

  defp finish(state, result) do
    cancel_timeout(state.timeout_ref)

    send(state.notify, {:worker_finished, state.id, Map.put(result, :output, state.output)})
  end

  defp close_port(%__MODULE__{port: nil} = state), do: state

  defp close_port(%__MODULE__{port: port} = state) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    %{state | port: nil}
  end

  defp cancel_timeout(nil), do: :ok

  defp cancel_timeout(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp build_shell_command(cwd, command) do
    escaped_cwd = shell_escape(Path.expand(cwd))
    escaped_command = Enum.map_join(command, " ", &shell_escape/1)
    "cd #{escaped_cwd} && exec #{escaped_command}"
  end

  defp env_to_port(env) do
    Enum.map(env, fn {key, value} ->
      {to_charlist(to_string(key)), to_charlist(to_string(value))}
    end)
  end

  defp shell_escape(value) do
    "'#{String.replace(to_string(value), "'", "'\"'\"'")}'"
  end

  defp shell_path do
    System.find_executable("sh") || "/bin/sh"
  end
end
