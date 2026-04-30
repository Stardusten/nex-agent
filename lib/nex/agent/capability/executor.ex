defmodule Nex.Agent.Capability.Executor do
  @moduledoc false

  alias Nex.Agent.Knowledge.ProjectMemory, as: ProjectMemory
  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Runtime.Workspace
  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Sandbox.{Command, Exec, Policy}
  require Log

  @executor_names ~w(codex_cli claude_code_cli nex_local)
  @runs_file "runs.jsonl"

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    %{
      "executors" => Enum.map(@executor_names, &executor_status(&1, opts)),
      "recent_runs" => recent_runs(opts)
    }
  end

  @spec get_run(String.t(), keyword()) :: map() | nil
  def get_run(run_id, opts \\ []) when is_binary(run_id) do
    runs_file(opts)
    |> read_jsonl()
    |> Enum.find(&(&1["id"] == run_id))
  end

  @spec dispatch(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def dispatch(attrs, opts \\ []) when is_map(attrs) do
    Workspace.ensure!(opts)

    prompt =
      Map.get(attrs, "task") || Map.get(attrs, :task) || Map.get(attrs, "prompt") ||
        Map.get(attrs, :prompt)

    cwd = Map.get(attrs, "cwd") || Map.get(attrs, :cwd) || File.cwd!()
    requested = Map.get(attrs, "executor") || Map.get(attrs, :executor)

    project =
      Map.get(attrs, "project") || Map.get(attrs, :project) || ProjectMemory.detect_project(cwd)

    executor = requested || preferred_executor(opts)

    cond do
      not is_binary(prompt) or String.trim(prompt) == "" ->
        {:error, "task is required"}

      executor == "nex_local" ->
        record =
          base_record(attrs, executor, cwd, project)
          |> Map.merge(%{
            "status" => "accepted",
            "exit_code" => 0,
            "output" =>
              "nex_local selected. Handle this task locally with the built-in tools unless an external executor is preferred."
          })

        persist_run(record, opts)
        {:ok, record}

      true ->
        case executor_config(executor, opts) do
          %{available: true} = config ->
            run_external_executor(prompt, executor, config, cwd, project, attrs, opts)

          %{configured: false} ->
            {:error,
             "Executor #{executor} is not configured. Add #{executor}.json under workspace/executors first."}

          %{available: false, executable: executable} ->
            {:error, "Executor #{executor} is configured but unavailable: #{executable}"}
        end
    end
  end

  @spec preferred_executor(keyword()) :: String.t()
  def preferred_executor(opts \\ []) do
    Enum.find_value(~w(codex_cli claude_code_cli), "nex_local", fn name ->
      config = executor_config(name, opts)
      if config.available, do: name
    end)
  end

  @spec recent_runs(keyword()) :: [map()]
  def recent_runs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    runs_file(opts)
    |> read_jsonl()
    |> Enum.take(-limit)
    |> Enum.reverse()
  end

  @spec executor_status(String.t(), keyword()) :: map()
  def executor_status(name, opts \\ []) when name in @executor_names do
    if name == "nex_local" do
      %{
        "name" => name,
        "configured" => true,
        "available" => true,
        "prompt_mode" => "local",
        "executable" => "internal"
      }
    else
      config = executor_config(name, opts)

      %{
        "name" => name,
        "configured" => config.configured,
        "available" => config.available,
        "prompt_mode" => config.prompt_mode,
        "executable" => config.executable,
        "timeout" => config.timeout
      }
    end
  end

  defp run_external_executor(prompt, executor, config, cwd, project, attrs, opts) do
    id = generate_run_id()
    started_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    command = config.executable
    args = build_args(config, prompt)

    case run_command(command, args, config, prompt, cwd, attrs, opts) do
      {:ok, result} ->
        record =
          base_record(attrs, executor, cwd, project)
          |> Map.merge(%{
            "id" => id,
            "started_at" => started_at,
            "completed_at" => now_iso(),
            "status" => if(result.exit_code == 0, do: "completed", else: "failed"),
            "command" => command,
            "args" => args,
            "exit_code" => result.exit_code,
            "output" => sanitize_output(result.stdout)
          })

        persist_run(record, opts)

        if result.exit_code == 0 do
          {:ok, record}
        else
          {:error, "Executor #{executor} failed with exit code #{result.exit_code}"}
        end

      {:error, %{status: :timeout}} ->
        record =
          base_record(attrs, executor, cwd, project)
          |> Map.merge(%{
            "id" => id,
            "started_at" => started_at,
            "completed_at" => now_iso(),
            "status" => "failed",
            "command" => command,
            "args" => args,
            "error" => "timed out after #{config.timeout}s"
          })

        persist_run(record, opts)
        {:error, "Executor #{executor} timed out after #{config.timeout}s"}

      {:error, reason} ->
        message = executor_error_message(reason)

        record =
          base_record(attrs, executor, cwd, project)
          |> Map.merge(%{
            "id" => id,
            "started_at" => started_at,
            "completed_at" => now_iso(),
            "status" => "failed",
            "command" => command,
            "args" => args,
            "error" => message
          })

        persist_run(record, opts)
        {:error, "Executor #{executor} crashed: #{message}"}
    end
  end

  defp base_record(attrs, executor, cwd, project) do
    %{
      "id" => generate_run_id(),
      "executor" => executor,
      "task" =>
        Map.get(attrs, "task") || Map.get(attrs, :task) || Map.get(attrs, "prompt") ||
          Map.get(attrs, :prompt),
      "summary" => Map.get(attrs, "summary") || Map.get(attrs, :summary),
      "cwd" => cwd,
      "project" => project,
      "status" => "queued"
    }
  end

  defp persist_run(record, opts) do
    File.write!(runs_file(opts), Jason.encode!(record) <> "\n", [:append])
    Log.info("executor.dispatch.recorded", record, opts)

    if is_binary(record["project"]) and record["project"] != "" do
      ProjectMemory.append_run(record["project"], record, opts)
    end
  end

  defp runs_file(opts), do: Path.join(Workspace.executors_dir(opts), @runs_file)

  defp executor_config(name, opts) do
    path = Path.join(Workspace.executors_dir(opts), "#{name}.json")

    config =
      case File.read(path) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        {:error, _} ->
          %{}
      end

    enabled = Map.get(config, "enabled", false) == true
    executable = Map.get(config, "command") || default_executable(name)
    prompt_mode = Map.get(config, "prompt_mode", "stdin")
    timeout = Map.get(config, "timeout", 300)
    args = Map.get(config, "args", [])

    %{
      name: name,
      configured: enabled,
      available: enabled and not is_nil(System.find_executable(executable)),
      executable: executable,
      prompt_mode: prompt_mode,
      timeout: timeout,
      args: if(is_list(args), do: Enum.map(args, &to_string/1), else: [])
    }
  end

  defp default_executable("codex_cli"), do: "codex"
  defp default_executable("claude_code_cli"), do: "claude"

  defp build_args(%{prompt_mode: "arg_append", args: args}, prompt), do: args ++ [prompt]
  defp build_args(%{args: args}, _prompt), do: args

  defp run_command(command, args, config, prompt, cwd, attrs, opts) do
    Exec.run(
      %Command{
        program: command,
        args: args,
        cwd: cwd,
        stdin: if(config.prompt_mode == "stdin", do: prompt),
        timeout_ms: max(config.timeout, 1) * 1000,
        cancel_ref: Keyword.get(opts, :cancel_ref),
        metadata: %{
          workspace: Keyword.get(opts, :workspace, cwd),
          observe_context: %{
            workspace: Keyword.get(opts, :workspace, cwd),
            run_id: Map.get(attrs, :run_id) || Map.get(attrs, "run_id")
          },
          observe_attrs: %{"executor" => config.name}
        }
      },
      sandbox_policy(opts, cwd)
    )
  end

  defp sandbox_policy(opts, cwd) do
    case Keyword.get(opts, :runtime_snapshot) do
      %{sandbox: %Policy{} = policy} ->
        policy

      _ ->
        opts
        |> Keyword.get(:config)
        |> Config.sandbox_runtime(workspace: Keyword.get(opts, :workspace, cwd))
    end
  end

  defp executor_error_message(%{error: error}) when is_binary(error), do: error
  defp executor_error_message(%{status: status}), do: Atom.to_string(status)
  defp executor_error_message(reason), do: inspect(reason)

  defp read_jsonl(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _} ->
        []
    end
  end

  defp sanitize_output(output) when is_binary(output) do
    if String.valid?(output), do: output, else: Base.encode64(output)
  end

  defp sanitize_output(output), do: inspect(output)

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp generate_run_id do
    "exec_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
