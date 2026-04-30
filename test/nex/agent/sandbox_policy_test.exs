defmodule Nex.Agent.SandboxPolicyTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Sandbox.{Command, Policy, Result}

  test "policy command and result structs expose stable defaults" do
    assert %Policy{
             enabled: true,
             backend: :auto,
             mode: :workspace_write,
             network: :restricted,
             filesystem: [],
             protected_names: [".git", ".agents", ".codex"],
             env_allowlist: ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "NO_COLOR"],
             raw: %{}
           } = %Policy{}

    assert %Command{
             program: "",
             args: [],
             cwd: "",
             env: %{},
             stdin: nil,
             timeout_ms: 30_000,
             cancel_ref: nil,
             metadata: %{}
           } = %Command{}

    assert %Result{
             status: :error,
             exit_code: nil,
             stdout: "",
             stderr: "",
             duration_ms: 0,
             sandbox: %{},
             error: nil
           } = %Result{}
  end

  test "default sandbox runtime injects hard protected paths" do
    policy = Config.sandbox_runtime(Config.default())

    zshrc = Path.expand("~/.zshrc")
    config_path = Path.expand("~/.nex/agent/config.json")

    assert zshrc in policy.protected_paths
    assert config_path in policy.protected_paths
    assert %{path: {:path, zshrc}, access: :none} in policy.filesystem
    assert %{path: {:path, config_path}, access: :none} in policy.filesystem
    assert %{path: {:special, :workspace}, access: :write} in policy.filesystem
    assert %{path: {:special, :tmp}, access: :write} in policy.filesystem
    assert %{path: {:special, :slash_tmp}, access: :write} in policy.filesystem
  end
end
