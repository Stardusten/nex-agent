defmodule Nex.Agent.SandboxExecTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Conversation.RunControl
  alias Nex.Agent.Observe.ControlPlane.Query
  alias Nex.Agent.Sandbox.{Command, Exec, Policy}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-sandbox-exec-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "run returns completed output and records observations", %{workspace: workspace} do
    assert {:ok, result} =
             Exec.run(
               command("sh",
                 args: ["-c", "printf hello"],
                 metadata: %{observe_context: %{workspace: workspace, run_id: "run_sandbox"}}
               ),
               noop_policy()
             )

    assert result.status == :ok
    assert result.exit_code == 0
    assert result.stdout == "hello"
    assert result.sandbox["backend"] == "noop"

    assert [started] = Query.query(%{"tag" => "sandbox.exec.started"}, workspace: workspace)
    assert started["context"]["run_id"] == "run_sandbox"
    assert started["attrs"]["program"] == "sh"

    assert [finished] = Query.query(%{"tag" => "sandbox.exec.ok"}, workspace: workspace)
    assert finished["attrs"]["status"] == "ok"
  end

  test "run supports stdin without inheriting arbitrary env", %{workspace: workspace} do
    previous_secret = System.get_env("NEX_AGENT_EXEC_SECRET")
    previous_public = System.get_env("NEX_AGENT_EXEC_PUBLIC")

    System.put_env("NEX_AGENT_EXEC_SECRET", "secret")
    System.put_env("NEX_AGENT_EXEC_PUBLIC", "public")

    on_exit(fn ->
      restore_env("NEX_AGENT_EXEC_SECRET", previous_secret)
      restore_env("NEX_AGENT_EXEC_PUBLIC", previous_public)
    end)

    policy = %Policy{
      noop_policy()
      | env_allowlist: ["NEX_AGENT_EXEC_PUBLIC"]
    }

    assert {:ok, result} =
             Exec.run(
               command("sh",
                 args: [
                   "-c",
                   "cat; printf '|%s:%s:%s' \"$NEX_AGENT_EXEC_SECRET\" \"$NEX_AGENT_EXEC_PUBLIC\" \"$EXPLICIT\""
                 ],
                 stdin: "payload",
                 env: %{"EXPLICIT" => "kept"},
                 metadata: %{observe_context: %{workspace: workspace}}
               ),
               policy
             )

    assert result.stdout == "payload|:public:kept"
  end

  test "run reports nonzero exits, timeouts, and missing executables", %{workspace: workspace} do
    assert {:error, exit_result} =
             Exec.run(
               command("sh",
                 args: ["-c", "printf nope; exit 7"],
                 metadata: %{observe_context: %{workspace: workspace}}
               ),
               noop_policy()
             )

    assert exit_result.status == :exit
    assert exit_result.exit_code == 7
    assert exit_result.stdout == "nope"

    assert {:error, timeout_result} =
             Exec.run(
               command("sh",
                 args: ["-c", "sleep 1"],
                 timeout_ms: 50,
                 metadata: %{observe_context: %{workspace: workspace}}
               ),
               noop_policy()
             )

    assert timeout_result.status == :timeout

    assert {:error, missing_result} =
             Exec.run(
               command("definitely-not-a-nex-agent-executable",
                 metadata: %{observe_context: %{workspace: workspace}}
               ),
               noop_policy()
             )

    assert missing_result.status == :error
    assert missing_result.error =~ "executable not found"
  end

  test "run honors owner cancellation", %{workspace: workspace} do
    if Process.whereis(RunControl) == nil do
      start_supervised!({RunControl, name: RunControl})
    end

    session_key = "feishu:sandbox-cancel"
    assert {:ok, run} = RunControl.start_owner(workspace, session_key, %{})

    task =
      Task.async(fn ->
        Exec.run(
          command("sh",
            args: ["-c", "sleep 5"],
            timeout_ms: 5_000,
            cancel_ref: run.cancel_ref,
            metadata: %{observe_context: %{workspace: workspace, run_id: run.id}}
          ),
          noop_policy()
        )
      end)

    Process.sleep(100)
    assert {:ok, %{cancelled?: true}} = RunControl.cancel_owner(workspace, session_key, :stop)
    assert {:error, result} = Task.await(task, 1_000)
    assert result.status == :cancelled
  end

  test "enabled policy fails closed when requested backend is unavailable", %{
    workspace: workspace
  } do
    policy = %Policy{noop_policy() | backend: :linux}

    assert {:error, result} =
             Exec.run(
               command("sh",
                 args: ["-c", "printf should-not-run"],
                 metadata: %{observe_context: %{workspace: workspace}}
               ),
               policy
             )

    assert result.status == :denied
    assert result.error =~ "unsupported_backend"
  end

  defp command(program, opts) do
    %Command{
      program: program,
      args: Keyword.get(opts, :args, []),
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      env: Keyword.get(opts, :env, %{}),
      stdin: Keyword.get(opts, :stdin),
      timeout_ms: Keyword.get(opts, :timeout_ms, 1_000),
      cancel_ref: Keyword.get(opts, :cancel_ref),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp noop_policy do
    %Policy{
      enabled: true,
      backend: :noop,
      mode: :workspace_write,
      network: :restricted,
      filesystem: [],
      protected_paths: [],
      protected_names: [],
      env_allowlist: ["PATH"],
      raw: %{}
    }
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
