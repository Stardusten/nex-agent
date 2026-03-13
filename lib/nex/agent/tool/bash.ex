defmodule Nex.Agent.Tool.Bash do
  @moduledoc false

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Security

  def name, do: "bash"
  def description, do: "Execute a shell command"
  def category, do: :base

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

  def execute(%{"command" => command}, ctx) do
    do_execute(command, ctx)
  end

  def execute(_args, _ctx), do: {:error, "command is required"}

  defp do_execute(command, ctx) do
    cwd = Map.get(ctx, :cwd, File.cwd!())
    timeout = (Map.get(ctx, "timeout") || Map.get(ctx, :timeout, 120)) * 1000

    case Security.validate_command(command) do
      :ok ->
        task =
          Task.async(fn ->
            System.cmd("sh", ["-c", command], stderr_to_stdout: true, cd: cwd)
          end)

        result =
          try do
            Task.await(task, timeout)
          rescue
            _ ->
              Task.shutdown(task, :brutal_kill)
              {:error, :timeout}
          end

        case result do
          {:error, :timeout} ->
            {:error, "Command timed out after #{div(timeout, 1000)} seconds"}

          {output, exit_code} ->
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
              {:ok, "Exit code #{exit_code}\n#{truncated}"}
            end
        end

      {:error, reason} ->
        {:error, "Security: #{reason}"}
    end
  end

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
