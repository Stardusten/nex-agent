defmodule Nex.Agent.SandboxProcessTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Sandbox.{Command, Exec, Policy}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-sandbox-process-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "open/write/close exposes a bidirectional port", %{workspace: workspace} do
    assert {:ok, process} =
             Exec.open(
               %Command{
                 program: "sh",
                 args: ["-c", "while IFS= read -r line; do printf 'mcp:%s\\n' \"$line\"; done"],
                 cwd: File.cwd!(),
                 timeout_ms: 1_000,
                 metadata: %{observe_context: %{workspace: workspace}}
               },
               noop_policy()
             )

    assert is_port(process.port)
    assert process.sandbox["backend"] == "noop"

    assert :ok = Exec.write(process, "ping\n")
    assert_receive {port, {:data, "mcp:ping\n"}}, 1_000
    assert port == process.port

    assert :ok = Exec.close(process)
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
end
