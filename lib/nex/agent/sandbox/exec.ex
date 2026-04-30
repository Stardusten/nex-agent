defmodule Nex.Agent.Sandbox.Exec do
  @moduledoc """
  Unified child process execution entry point for sandboxed commands.
  """

  alias Nex.Agent.Conversation.RunControl
  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Sandbox.Backends.{Noop, Seatbelt}
  alias Nex.Agent.Sandbox.{Command, Policy, Result}
  alias Nex.Agent.Sandbox.Process, as: SandboxProcess
  require Log

  @poll_ms 50
  @max_output_bytes 50_000

  @spec run(Command.t(), Policy.t()) :: {:ok, Result.t()} | {:error, Result.t()}
  def run(%Command{} = command, %Policy{} = policy) do
    started_at = System.monotonic_time(:millisecond)

    try do
      do_run(command, policy, started_at)
    rescue
      error ->
        result =
          error_result(:error, Exception.message(error), started_at, sandbox_info(:none, policy))

        {:error, result}
    catch
      :exit, reason ->
        result = error_result(:error, inspect(reason), started_at, sandbox_info(:none, policy))
        {:error, result}
    end
  end

  defp do_run(%Command{} = command, %Policy{} = policy, started_at) do
    with {:ok, command} <- normalize_command(command),
         {:ok, command, stdin_file} <- maybe_rewrite_stdin(command),
         {:ok, backend, wrapped} <- wrap_command(command, policy) do
      sandbox = sandbox_info(backend, policy)
      emit(:info, "sandbox.exec.started", wrapped, policy, sandbox, started_at, %{})

      try do
        port = open_port!(wrapped, env_for(policy, wrapped), [:exit_status])

        result =
          collect_port(port, output_buffer(), wrapped.timeout_ms, started_at, wrapped.cancel_ref)

        result = %{result | sandbox: sandbox}
        emit_result(result, wrapped, policy, sandbox, started_at)
        result_tuple(result)
      after
        cleanup_stdin_file(stdin_file)
      end
    else
      {:error, %Result{} = result} ->
        {:error, result}

      {:error, reason} ->
        result =
          error_result(:error, reason, started_at, sandbox_info(:none, policy))

        {:error, result}
    end
  end

  @spec open(Command.t(), Policy.t()) :: {:ok, SandboxProcess.t()} | {:error, term()}
  def open(%Command{} = command, %Policy{} = policy) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, command} <- normalize_command(%{command | stdin: nil}),
         {:ok, backend, wrapped} <- wrap_command(command, policy) do
      sandbox = sandbox_info(backend, policy)
      emit(:info, "sandbox.process.started", wrapped, policy, sandbox, started_at, %{})

      port = open_port!(wrapped, env_for(policy, wrapped), [:eof, :exit_status])

      {:ok,
       %SandboxProcess{
         id: new_process_id(),
         port: port,
         command: wrapped,
         policy: policy,
         sandbox: sandbox
       }}
    else
      {:error, %Result{} = result} -> {:error, result.error || result.status}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec write(SandboxProcess.t(), iodata()) :: :ok | {:error, term()}
  def write(%SandboxProcess{port: port}, data) do
    Port.command(port, data)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec close(SandboxProcess.t()) :: :ok
  def close(%SandboxProcess{port: port}) do
    safe_close(port)
  end

  defp normalize_command(%Command{} = command) do
    cwd = normalize_cwd(command.cwd)
    args = Enum.map(command.args || [], &to_string/1)
    env = normalize_env(command.env || %{})

    with {:ok, program} <- resolve_executable(command.program, cwd),
         {:ok, timeout_ms} <- normalize_timeout(command.timeout_ms) do
      {:ok,
       %Command{
         command
         | program: program,
           args: args,
           cwd: cwd,
           env: env,
           timeout_ms: timeout_ms,
           metadata: command.metadata || %{}
       }}
    end
  end

  defp normalize_cwd(nil), do: File.cwd!()
  defp normalize_cwd(""), do: File.cwd!()
  defp normalize_cwd(cwd) when is_binary(cwd), do: Path.expand(cwd)
  defp normalize_cwd(cwd), do: cwd |> to_string() |> Path.expand()

  defp resolve_executable(program, cwd) when is_binary(program) and program != "" do
    cond do
      Path.type(program) == :absolute ->
        {:ok, program}

      String.contains?(program, "/") ->
        {:ok, Path.expand(program, cwd)}

      executable = System.find_executable(program) ->
        {:ok, executable}

      true ->
        {:error, "executable not found: #{program}"}
    end
  end

  defp resolve_executable(_program, _cwd), do: {:error, "program is required"}

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}

  defp normalize_timeout(timeout) when is_float(timeout) and timeout > 0,
    do: {:ok, trunc(timeout)}

  defp normalize_timeout(_timeout), do: {:error, "timeout_ms must be positive"}

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env(_env), do: %{}

  defp maybe_rewrite_stdin(%Command{stdin: stdin} = command) when is_binary(stdin) do
    path = temp_stdin_path()

    with :ok <- File.write(path, stdin),
         {:ok, shell} <- resolve_executable("sh", command.cwd) do
      {:ok,
       %Command{
         command
         | program: shell,
           args: [
             "-c",
             "cat \"$NEX_AGENT_STDIN_FILE\" | exec \"$NEX_AGENT_EXECUTABLE\" \"$@\"",
             "nex-agent-stdin"
             | command.args
           ],
           env:
             Map.merge(command.env, %{
               "NEX_AGENT_STDIN_FILE" => path,
               "NEX_AGENT_EXECUTABLE" => command.program
             }),
           stdin: nil
       }, path}
    else
      {:error, reason} ->
        _ = File.rm(path)
        {:error, reason}
    end
  end

  defp maybe_rewrite_stdin(%Command{} = command), do: {:ok, command, nil}

  defp temp_stdin_path do
    Path.join(System.tmp_dir!(), "nex-agent-stdin-#{System.unique_integer([:positive])}.txt")
  end

  defp cleanup_stdin_file(nil), do: :ok
  defp cleanup_stdin_file(path), do: File.rm(path)

  defp wrap_command(%Command{} = command, %Policy{} = policy) do
    case select_backend(policy) do
      {:ok, backend_module} ->
        case apply(backend_module, :wrap, [command, policy]) do
          {:ok, wrapped} -> {:ok, backend_module.name(), wrapped}
          {:error, reason} -> {:error, denied_result(reason, policy)}
        end

      {:error, reason} ->
        {:error, denied_result(reason, policy)}
    end
  end

  defp select_backend(%Policy{enabled: false}), do: {:ok, Noop}

  defp select_backend(%Policy{mode: mode}) when mode in [:danger_full_access, :external],
    do: {:ok, Noop}

  defp select_backend(%Policy{backend: :noop}), do: {:ok, Noop}

  defp select_backend(%Policy{backend: :seatbelt}) do
    if Seatbelt.available?(), do: {:ok, Seatbelt}, else: {:error, :seatbelt_unavailable}
  end

  defp select_backend(%Policy{backend: :auto}) do
    case :os.type() do
      {:unix, :darwin} ->
        if Seatbelt.available?(), do: {:ok, Seatbelt}, else: {:error, :seatbelt_unavailable}

      _other ->
        {:error, :sandbox_backend_unavailable}
    end
  end

  defp select_backend(%Policy{backend: backend}), do: {:error, {:unsupported_backend, backend}}

  defp denied_result(reason, policy) do
    %Result{
      status: :denied,
      exit_code: nil,
      stdout: "",
      stderr: "",
      duration_ms: 0,
      sandbox: sandbox_info(:none, policy),
      error: format_reason(reason)
    }
  end

  defp env_for(%Policy{} = policy, %Command{} = command) do
    system_env =
      policy.env_allowlist
      |> Enum.flat_map(fn key ->
        case System.get_env(key) do
          nil -> []
          value -> [{key, value}]
        end
      end)
      |> Map.new()

    system_env
    |> Map.merge(command.env || %{})
    |> then(fn allowed_env ->
      allowed_keys = MapSet.new(Map.keys(allowed_env))

      unset_env =
        System.get_env()
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(allowed_keys, &1))
        |> Enum.map(&{String.to_charlist(&1), false})

      set_env =
        Enum.map(allowed_env, fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end)

      unset_env ++ set_env
    end)
  end

  defp open_port!(%Command{} = command, env, extra_opts) do
    Port.open(
      {:spawn_executable, command.program},
      [
        :binary,
        :stderr_to_stdout,
        args: command.args,
        cd: command.cwd,
        env: env
      ] ++ extra_opts
    )
  end

  defp output_buffer, do: %{data: "", bytes: 0, truncated?: false}

  defp collect_port(port, buffer, timeout_ms, started_at, cancel_ref) do
    cond do
      cancelled?(cancel_ref) ->
        safe_close(port)
        result(:cancelled, nil, buffer, started_at, "Command cancelled")

      elapsed_ms(started_at) >= timeout_ms ->
        safe_close(port)
        result(:timeout, nil, buffer, started_at, "Command timed out after #{timeout_ms}ms")

      true ->
        receive do
          {^port, {:data, chunk}} ->
            collect_port(port, append_output(buffer, chunk), timeout_ms, started_at, cancel_ref)

          {^port, {:exit_status, exit_code}} ->
            status = if exit_code == 0, do: :ok, else: :exit
            error = if exit_code == 0, do: nil, else: "Exit code #{exit_code}"
            result(status, exit_code, buffer, started_at, error)
        after
          @poll_ms ->
            collect_port(port, buffer, timeout_ms, started_at, cancel_ref)
        end
    end
  end

  defp append_output(%{bytes: bytes} = buffer, chunk) when is_binary(chunk) do
    remaining = max(@max_output_bytes - bytes, 0)

    cond do
      remaining == 0 ->
        %{buffer | truncated?: true}

      byte_size(chunk) <= remaining ->
        %{buffer | data: buffer.data <> chunk, bytes: bytes + byte_size(chunk)}

      true ->
        <<keep::binary-size(remaining), _rest::binary>> = chunk
        %{buffer | data: buffer.data <> keep, bytes: @max_output_bytes, truncated?: true}
    end
  end

  defp result(status, exit_code, buffer, started_at, error) do
    stdout =
      buffer.data
      |> sanitize_output()
      |> maybe_append_truncation(buffer.truncated?)

    %Result{
      status: status,
      exit_code: exit_code,
      stdout: stdout,
      stderr: "",
      duration_ms: elapsed_ms(started_at),
      error: error
    }
  end

  defp error_result(status, reason, started_at, sandbox) do
    %Result{
      status: status,
      exit_code: nil,
      stdout: "",
      stderr: "",
      duration_ms: elapsed_ms(started_at),
      sandbox: sandbox,
      error: format_reason(reason)
    }
  end

  defp result_tuple(%Result{status: :ok} = result), do: {:ok, result}
  defp result_tuple(%Result{} = result), do: {:error, result}

  defp sanitize_output(output) when is_binary(output) do
    if String.valid?(output) do
      output
    else
      preview =
        output
        |> binary_part(0, min(byte_size(output), 256))
        |> Base.encode64()

      "Binary output (#{byte_size(output)} bytes, base64 preview): #{preview}"
    end
  end

  defp maybe_append_truncation(output, true), do: output <> "\n\n[Output truncated]"
  defp maybe_append_truncation(output, false), do: output

  defp cancelled?(ref) when is_reference(ref), do: RunControl.cancelled?(ref)
  defp cancelled?(_ref), do: false

  defp safe_close(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp sandbox_info(backend, %Policy{} = policy) do
    %{
      "backend" => Atom.to_string(backend),
      "mode" => Atom.to_string(policy.mode),
      "network" => Atom.to_string(policy.network),
      "enabled" => policy.enabled
    }
  end

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at

  defp emit_result(%Result{} = result, command, policy, sandbox, started_at) do
    level =
      case result.status do
        :ok -> :info
        :exit -> :warning
        :timeout -> :warning
        :cancelled -> :warning
        _ -> :error
      end

    tag = "sandbox.exec.#{result.status}"

    emit(level, tag, command, policy, sandbox, started_at, %{
      "status" => Atom.to_string(result.status),
      "exit_code" => result.exit_code,
      "duration_ms" => result.duration_ms,
      "stdout_bytes" => byte_size(result.stdout || ""),
      "reason_type" => result.error
    })
  end

  defp emit(level, tag, %Command{} = command, %Policy{} = policy, sandbox, started_at, attrs) do
    metadata = command.metadata || %{}
    context = Map.get(metadata, :observe_context) || Map.get(metadata, "observe_context") || %{}
    observe_attrs = Map.get(metadata, :observe_attrs) || Map.get(metadata, "observe_attrs") || %{}

    attrs =
      %{
        "program" => Path.basename(command.program || ""),
        "args_count" => length(command.args || []),
        "cwd" => command.cwd,
        "backend" => sandbox["backend"],
        "policy_mode" => Atom.to_string(policy.mode),
        "network" => Atom.to_string(policy.network),
        "elapsed_ms" => elapsed_ms(started_at)
      }
      |> Map.merge(observe_attrs)
      |> Map.merge(attrs)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    observe_opts =
      case Map.get(metadata, :observe_opts, Map.get(metadata, "observe_opts", [])) do
        opts when is_list(opts) -> opts
        _other -> []
      end

    opts =
      observe_opts
      |> Keyword.merge(context: context)
      |> Keyword.put_new(
        :workspace,
        Map.get(context, :workspace) || Map.get(context, "workspace")
      )

    case level do
      :info -> Log.info(tag, attrs, opts)
      :warning -> Log.warning(tag, attrs, opts)
      :error -> Log.error(tag, attrs, opts)
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp new_process_id do
    "proc_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
