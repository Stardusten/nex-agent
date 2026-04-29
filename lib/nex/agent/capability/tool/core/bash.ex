defmodule Nex.Agent.Capability.Tool.Core.Bash do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Sandbox.Security

  def name, do: "bash"
  def description, do: "Execute a shell command"
  def category, do: :base
  def surfaces, do: [:all, :base, :subagent, :cron]

  def definition do
    %{
      name: "bash",
      description: "Execute a shell command.",
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "Command to execute"},
          timeout: %{
            type: "number",
            description: "Timeout in seconds (default: 120)",
            default: 120
          }
        },
        required: ["command"]
      }
    }
  end

  def execute(%{"command" => command} = args, ctx) do
    do_execute(command, args, ctx)
  end

  def execute(_args, _ctx), do: {:error, "command is required"}

  defp do_execute(command, args, ctx) do
    cwd = Map.get(ctx, :cwd, File.cwd!())
    cancel_ref = Map.get(ctx, :cancel_ref)

    timeout =
      args
      |> Map.get("timeout", Map.get(ctx, "timeout") || Map.get(ctx, :timeout, 120))
      |> normalize_timeout()

    case Security.validate_command(command) do
      :ok ->
        run_cancellable_command(command, cwd, timeout, cancel_ref)

      {:error, reason} ->
        {:error, "Security: #{reason}"}
    end
  end

  defp run_cancellable_command(command, cwd, timeout, cancel_ref) do
    port =
      Port.open({:spawn_executable, System.find_executable("sh") || "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", command],
        cd: cwd
      ])

    started_at = System.monotonic_time(:millisecond)
    collect_port_output(port, "", timeout, started_at, cancel_ref)
  end

  defp collect_port_output(port, output, timeout, started_at, cancel_ref) do
    cond do
      cancelled?(cancel_ref) ->
        Port.close(port)
        {:error, "Command cancelled"}

      System.monotonic_time(:millisecond) - started_at >= timeout ->
        Port.close(port)
        {:error, "Command timed out after #{div(timeout, 1000)} seconds"}

      true ->
        receive do
          {^port, {:data, chunk}} ->
            collect_port_output(port, output <> chunk, timeout, started_at, cancel_ref)

          {^port, {:exit_status, exit_code}} ->
            handle_command_result(output, exit_code)
        after
          50 ->
            collect_port_output(port, output, timeout, started_at, cancel_ref)
        end
    end
  end

  defp cancelled?(ref) when is_reference(ref),
    do: Nex.Agent.Conversation.RunControl.cancelled?(ref)

  defp cancelled?(_ref), do: false

  defp handle_command_result(output, exit_code) do
    safe_output = sanitize_shell_output(output)

    truncated =
      if byte_size(safe_output) > 50_000 do
        String.slice(safe_output, 0, 50_000) <> "\n\n[Output truncated]"
      else
        safe_output
      end

    if exit_code == 0 do
      {:ok, truncated}
    else
      {:error, format_nonzero_exit(exit_code, truncated)}
    end
  end

  defp format_nonzero_exit(exit_code, ""), do: "Exit code #{exit_code}"
  defp format_nonzero_exit(exit_code, output), do: "Exit code #{exit_code}\n#{output}"

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout * 1000

  defp normalize_timeout(timeout) when is_float(timeout) and timeout > 0,
    do: trunc(timeout * 1000)

  defp normalize_timeout(_), do: 120_000

  defp sanitize_shell_output(output) when is_binary(output) do
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

  defp sanitize_shell_output(other), do: inspect(other)
end
