defmodule Nex.Agent.Self.Update.Deployer do
  @moduledoc false

  alias Nex.Agent.Observe.ControlPlane.Log, as: ControlPlaneLog
  alias Nex.Agent.{Self.CodeUpgrade, Self.HotReload}
  alias Nex.Agent.Self.Update.{Planner, ReleaseStore}
  require ControlPlaneLog

  @rollback_baseline "__baseline__"
  @test_timeout_ms 20_000
  @max_test_output_bytes 12_000

  @spec status(nil | [String.t()]) :: map()
  def status(files \\ nil) do
    release_state = ReleaseStore.release_state()
    plan_source = if is_list(files), do: :explicit, else: :pending_git

    case Planner.plan(files) do
      {:ok, plan, warnings} ->
        %{
          status: :ok,
          plan_source: plan_source,
          current_effective_release: release_id(release_state.current_effective_release),
          current_event_release: release_id(release_state.current_event_release),
          previous_rollback_target: release_id(release_state.previous_rollback_target),
          pending_files: Enum.map(plan, & &1.relative_path),
          modules: Enum.map(plan, & &1.module_name),
          related_tests: plan |> Enum.map(& &1.test) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
          rollback_candidates: Enum.map(release_state.rollback_candidates, &release_id/1),
          deployable: true,
          blocked_reasons: [],
          warnings: warnings
        }

      {:error, reason} ->
        %{
          status: :ok,
          plan_source: plan_source,
          current_effective_release: release_id(release_state.current_effective_release),
          current_event_release: release_id(release_state.current_event_release),
          previous_rollback_target: release_id(release_state.previous_rollback_target),
          pending_files: [],
          modules: [],
          related_tests: [],
          rollback_candidates: Enum.map(release_state.rollback_candidates, &release_id/1),
          deployable: false,
          blocked_reasons: [reason],
          warnings: []
        }
    end
  end

  @spec history() :: map()
  def history, do: ReleaseStore.history_view()

  @spec deploy(String.t(), nil | [String.t()], keyword()) :: map()
  def deploy(reason, files \\ nil, opts \\ []) when is_binary(reason) do
    started_at = System.monotonic_time(:millisecond)
    workspace = deploy_workspace(opts)
    started_attrs = deploy_attrs(%{status: :started}, files, 0)
    emit_deploy_observation(:info, "self_update.deploy.started", started_attrs, workspace)

    result = do_deploy(reason, files)
    emit_deploy_result_observation(result, reason, files, workspace, started_at)
    result
  end

  defp do_deploy(reason, files) when is_binary(reason) do
    with {:ok, plan, warnings} <- Planner.plan(files),
         :ok <- syntax_check(plan),
         {:ok, snapshot} <- snapshot_files(plan),
         {:ok, _reloads} <- compile_and_reload(plan, snapshot),
         {:ok, tests} <- run_related_tests(plan, snapshot) do
      persist_release(:deployed, reason, plan, snapshot, tests, warnings)
    else
      {:error, phase, snapshot, reason} ->
        failed_result(phase, snapshot, reason)

      {:error, reason} ->
        failed_result(:plan, [], reason)
    end
  end

  @spec rollback(String.t() | nil) :: map()
  def rollback(target \\ nil) do
    with {:ok, rollback_target} <- resolve_rollback_target(target),
         {:ok, plan, current_snapshot} <- rollback_plan(rollback_target),
         :ok <- syntax_check_contents(plan),
         {:ok, _reloads} <- write_and_reload_contents(plan, current_snapshot),
         {:ok, tests} <- run_related_tests(plan, current_snapshot) do
      persist_release(
        :rolled_back,
        rollback_reason(rollback_target.target_release_id),
        plan,
        current_snapshot,
        tests,
        [],
        %{target_release_id: rollback_target.target_release_id}
      )
    else
      {:error, phase, snapshot, reason} ->
        warnings = if(snapshot == [], do: [], else: ["Rollback target restore failed"])
        failed_result(phase, snapshot, reason, warnings)

      {:error, reason} ->
        failed_result(:plan, [], reason)
    end
  end

  defp persist_release(status, reason, plan, snapshot, tests, warnings, extra \\ %{}) do
    ReleaseStore.ensure_layout()
    release_id = ReleaseStore.new_release_id()
    parent = ReleaseStore.current_event_release()

    Enum.each(snapshot, fn entry ->
      :ok = ReleaseStore.save_snapshot(release_id, entry.relative_path, entry.original_content)
    end)

    Enum.each(plan, fn entry ->
      :ok = ReleaseStore.save_applied(release_id, entry.relative_path, file_content(entry))
    end)

    release = %{
      "id" => release_id,
      "parent_release_id" => release_id(parent),
      "timestamp" => ReleaseStore.new_timestamp(),
      "reason" => reason,
      "files" =>
        Enum.map(plan, fn entry ->
          before_entry = Enum.find(snapshot, &(&1.relative_path == entry.relative_path))

          %{
            "path" => entry.relative_path,
            "before_sha" => sha256(before_entry.original_content),
            "after_sha" => sha256(file_content(entry))
          }
        end),
      "modules" => Enum.map(plan, & &1.module_name),
      "tests" => tests,
      "status" => Atom.to_string(status)
    }

    :ok = ReleaseStore.save_release(release)

    %{
      status: status,
      release_id: release_id,
      parent_release_id: release_id(parent),
      reason: reason,
      files: Enum.map(plan, & &1.relative_path),
      modules: Enum.map(plan, & &1.module_name),
      tests: tests,
      rollback_available: true,
      warnings: warnings
    }
    |> Map.merge(extra)
  end

  defp snapshot_files(plan) do
    snapshot =
      Enum.map(plan, fn entry ->
        %{
          path: entry.path,
          relative_path: entry.relative_path,
          module: entry.module,
          module_name: entry.module_name,
          original_content: snapshot_content(entry)
        }
      end)

    {:ok, snapshot}
  rescue
    e ->
      {:error, "Unable to snapshot deploy files: #{Exception.message(e)}"}
  end

  defp snapshot_content(entry) do
    case current_state_content(entry.relative_path) do
      {:ok, content} ->
        content

      :error ->
        case git_head_content(entry.relative_path) do
          {:ok, content} -> content
          :error -> File.read!(entry.path)
        end
    end
  end

  defp git_head_content(relative_path) do
    case System.cmd("git", ["show", "HEAD:#{relative_path}"],
           cd: CodeUpgrade.repo_root(),
           stderr_to_stdout: true
         ) do
      {content, 0} -> {:ok, content}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp syntax_check(plan) do
    entries = Enum.map(plan, &Map.put(&1, :content, File.read!(&1.path)))
    syntax_check_contents(entries)
  rescue
    e ->
      {:error, :syntax, [], Exception.message(e)}
  end

  defp syntax_check_contents(entries) do
    case Enum.find_value(entries, fn entry ->
           case Code.string_to_quoted(entry.content) do
             {:ok, _ast} ->
               nil

             {:error, reason} ->
               {:error, :syntax, [],
                "Syntax check failed for #{entry.relative_path}: #{inspect(reason)}"}
           end
         end) do
      nil -> :ok
      error -> error
    end
  end

  defp compile_and_reload(plan, snapshot) do
    Enum.reduce_while(plan, {:ok, []}, fn entry, {:ok, acc} ->
      content = File.read!(entry.path)
      result = HotReload.reload_expected(entry.path, content, entry.module)

      if result.reload_succeeded do
        {:cont, {:ok, [entry | acc]}}
      else
        {:halt, {:error, :compile, snapshot, result.reason}}
      end
    end)
  rescue
    e ->
      {:error, :compile, snapshot, Exception.message(e)}
  end

  defp write_and_reload_contents(plan, snapshot) do
    Enum.each(plan, fn entry -> File.write!(entry.path, entry.content) end)

    Enum.reduce_while(plan, {:ok, []}, fn entry, {:ok, acc} ->
      result = HotReload.reload_expected(entry.path, entry.content, entry.module)

      if result.reload_succeeded do
        {:cont, {:ok, [entry | acc]}}
      else
        {:halt, {:error, :compile, snapshot, result.reason}}
      end
    end)
  rescue
    e ->
      {:error, :compile, snapshot, Exception.message(e)}
  end

  defp run_related_tests(plan, snapshot) do
    test_paths =
      plan
      |> Enum.map(& &1.test)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case run_test_plan(test_paths) do
      {:ok, tests} ->
        {:ok, tests}

      {:error, output} ->
        {:error, :tests, snapshot, output}
    end
  end

  defp run_test_plan([]), do: {:ok, []}

  defp run_test_plan(paths) do
    repo_root = CodeUpgrade.repo_root()
    relative_paths = Enum.map(paths, &Path.relative_to(&1, repo_root))
    {executable, args} = mix_test_command(relative_paths)

    task =
      Task.async(fn ->
        System.cmd(executable, args, stderr_to_stdout: true, cd: repo_root)
      end)

    receive do
      {ref, {_output, 0}} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        {:ok, Enum.map(paths, &%{path: &1, status: :passed})}

      {ref, {output, _status}} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        {:error, trim_output(output)}

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {:error, "test runner exited: #{inspect(reason)}"}
    after
      @test_timeout_ms ->
        Task.shutdown(task, :brutal_kill)
        {:error, "tests timed out after #{@test_timeout_ms}ms"}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp restore_snapshot(snapshot) do
    results =
      Enum.map(snapshot, fn entry ->
        try do
          case File.write(entry.path, entry.original_content) do
            :ok ->
              result = HotReload.reload_expected(entry.path, entry.original_content, entry.module)
              result.reload_succeeded

            {:error, _reason} ->
              false
          end
        rescue
          _ -> false
        end
      end)

    if Enum.all?(results), do: :best_effort, else: :none
  end

  defp failed_result(phase, snapshot, reason, warnings \\ []) do
    runtime_restored =
      if snapshot == [] do
        :none
      else
        restore_snapshot(snapshot)
      end

    %{
      status: :failed,
      phase: phase,
      rolled_back: snapshot != [],
      restored_files: Enum.map(snapshot, & &1.relative_path),
      runtime_restored: runtime_restored,
      error: normalize_error(reason),
      warnings: warnings
    }
  end

  defp emit_deploy_result_observation(
         %{status: :deployed} = result,
         _deploy_reason,
         files,
         workspace,
         started_at
       ) do
    attrs = deploy_attrs(result, files, duration_since(started_at))
    emit_deploy_observation(:info, "self_update.deploy.finished", attrs, workspace)
  end

  defp emit_deploy_result_observation(
         %{status: :failed} = result,
         deploy_reason,
         files,
         workspace,
         started_at
       ) do
    attrs = %{
      "phase" => "self_update.deploy",
      "duration_ms" => duration_since(started_at),
      "result_status" => "failed",
      "runtime_restored" => result.runtime_restored |> to_string(),
      "rolled_back" => result.rolled_back,
      "changed_files" => changed_files(result, files),
      "reason_type" => result.phase |> to_string(),
      "error_summary" => result.error,
      "actor" => %{
        "component" => "self_update",
        "module" => "Nex.Agent.Self.Update.Deployer"
      },
      "classifier" => %{
        "family" => "self_update",
        "deploy_phase" => result.phase |> to_string(),
        "rollback_attempted" => result.rolled_back
      },
      "evidence" => %{
        "reason" => deploy_reason,
        "files" => files || [],
        "self_update_error_summary" => result.error,
        "warnings" => result.warnings
      },
      "outcome" => %{
        "rolled_back" => result.rolled_back,
        "runtime_restored" => result.runtime_restored |> to_string()
      }
    }

    emit_deploy_observation(:error, "self_update.deploy.failed", attrs, workspace)
  end

  defp emit_deploy_result_observation(_result, _deploy_reason, _files, _workspace, _started_at),
    do: :ok

  defp emit_deploy_observation(level, tag, attrs, workspace) do
    result =
      case level do
        :info -> ControlPlaneLog.info(tag, attrs, workspace: workspace)
        :error -> ControlPlaneLog.error(tag, attrs, workspace: workspace)
      end

    case result do
      {:ok, _observation} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "[SelfUpdate.Deployer] control-plane deploy log failed: #{inspect(reason)}"
        )

      other ->
        require Logger

        Logger.warning(
          "[SelfUpdate.Deployer] control-plane deploy log #{tag} returned: #{inspect(other)}"
        )
    end
  rescue
    e ->
      require Logger

      Logger.warning(
        "[SelfUpdate.Deployer] control-plane deploy log crashed: #{Exception.message(e)}"
      )

      :ok
  end

  defp deploy_attrs(%{status: :started}, files, duration_ms) do
    %{
      "phase" => "self_update.deploy",
      "duration_ms" => duration_ms,
      "changed_files" => changed_files(%{}, files)
    }
  end

  defp deploy_attrs(%{status: :deployed} = result, files, duration_ms) do
    %{
      "phase" => "self_update.deploy",
      "release_id" => result.release_id,
      "duration_ms" => duration_ms,
      "result_status" => "ok",
      "rolled_back" => false,
      "changed_files" => changed_files(result, files)
    }
  end

  defp deploy_workspace(opts) do
    Keyword.get(opts, :workspace) ||
      Application.get_env(:nex_agent, :workspace_path) ||
      CodeUpgrade.repo_root()
  end

  defp changed_files(%{files: files}, _requested) when is_list(files), do: files
  defp changed_files(%{restored_files: files}, _requested) when is_list(files), do: files

  defp changed_files(_result, files) when is_list(files) do
    Enum.map(files, &Path.relative_to(&1, CodeUpgrade.repo_root()))
  end

  defp changed_files(_result, _files), do: []

  defp duration_since(started_at), do: System.monotonic_time(:millisecond) - started_at

  defp rollback_plan(%{restore_source: {:snapshot, release}}) do
    rollback_plan_from_release(release, &ReleaseStore.read_snapshot/2)
  end

  defp rollback_plan(%{restore_source: {:applied, release}}) do
    rollback_plan_from_release(release, &ReleaseStore.read_applied/2)
  end

  defp rollback_plan_from_release(release, reader) do
    plan =
      Enum.map(release["files"], fn file ->
        path = Path.join(CodeUpgrade.repo_root(), file["path"])
        {:ok, content} = reader.(release["id"], file["path"])
        module = detect_primary_module(content)

        %{
          path: path,
          relative_path: file["path"],
          module: module,
          module_name: module_name(module),
          test: related_test(path),
          content: content
        }
      end)

    current_snapshot =
      Enum.map(plan, fn entry ->
        %{
          path: entry.path,
          relative_path: entry.relative_path,
          module: entry.module,
          module_name: entry.module_name,
          original_content: current_file_content(entry.path)
        }
      end)

    {:ok, plan, current_snapshot}
  rescue
    e ->
      {:error, :plan, [], Exception.message(e)}
  end

  defp resolve_rollback_target(target) do
    ReleaseStore.resolve_rollback_target(target)
  end

  defp current_state_content(relative_path) do
    case ReleaseStore.current_effective_release() do
      nil ->
        :error

      release ->
        case ReleaseStore.read_applied(release["id"], relative_path) do
          {:ok, content} -> {:ok, content}
          {:error, _reason} -> :error
        end
    end
  end

  defp rollback_reason(nil), do: "rollback:#{@rollback_baseline}"
  defp rollback_reason(release_id), do: "rollback:#{release_id}"

  defp detect_primary_module(content) do
    case CodeUpgrade.detect_primary_module(content) do
      {:ok, module} -> module
      {:error, _reason} -> raise "Could not detect module name in rollback snapshot"
    end
  end

  defp related_test(path) do
    case CodeUpgrade.related_test_path(path) do
      {:ok, test_path, _repo_root} -> test_path
      :none -> nil
    end
  end

  defp release_id(nil), do: nil
  defp release_id(%{"id" => id}), do: id

  defp normalize_error(reason) when is_binary(reason), do: reason
  defp normalize_error(reason), do: inspect(reason)

  defp module_name(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end

  defp mix_test_command(relative_paths) do
    case System.find_executable("mix") do
      executable when is_binary(executable) ->
        {executable, ["test" | relative_paths]}

      nil ->
        case System.find_executable("mise") do
          executable when is_binary(executable) ->
            {executable, ["exec", "--", "mix", "test" | relative_paths]}

          nil ->
            {"mix", ["test" | relative_paths]}
        end
    end
  end

  defp current_file_content(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, :enoent} -> ""
      {:error, reason} -> raise "Unable to read current file #{path}: #{inspect(reason)}"
    end
  end

  defp file_content(%{content: content}), do: content
  defp file_content(%{path: path}), do: File.read!(path)

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp trim_output(output) do
    output = sanitize_output(output)

    if byte_size(output) > @max_test_output_bytes do
      utf8_prefix(output, @max_test_output_bytes) <>
        "\n... output truncated to #{@max_test_output_bytes} bytes"
    else
      output
    end
  end

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

  defp utf8_prefix(text, max_bytes) do
    text
    |> binary_part(0, max_bytes)
    |> trim_trailing_invalid_utf8()
  end

  defp trim_trailing_invalid_utf8(text) do
    cond do
      text == "" -> ""
      String.valid?(text) -> text
      true -> text |> binary_part(0, byte_size(text) - 1) |> trim_trailing_invalid_utf8()
    end
  end
end
