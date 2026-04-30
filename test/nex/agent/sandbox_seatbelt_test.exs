defmodule Nex.Agent.SandboxSeatbeltTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Sandbox.Backends.Seatbelt
  alias Nex.Agent.Sandbox.{Command, Exec, Policy}

  @moduletag :macos_seatbelt

  setup do
    if :os.type() == {:unix, :darwin} and Seatbelt.available?() do
      root =
        Path.join(System.tmp_dir!(), "nex-agent-seatbelt-#{System.unique_integer([:positive])}")

      allowed = Path.join(root, "allowed")
      blocked = Path.join(root, "blocked")
      File.mkdir_p!(allowed)
      File.mkdir_p!(blocked)

      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, seatbelt?: true, root: root, allowed: allowed, blocked: blocked}
    else
      {:ok, seatbelt?: false, root: nil, allowed: nil, blocked: nil}
    end
  end

  test "seatbelt allows configured writes and blocks other writes", %{
    seatbelt?: seatbelt?,
    allowed: allowed,
    blocked: blocked
  } do
    if seatbelt? do
      command =
        %Command{
          program: "sh",
          args: [
            "-c",
            "printf ok > \"$ALLOWED/out.txt\" && printf no > \"$BLOCKED/out.txt\""
          ],
          cwd: File.cwd!(),
          env: %{"ALLOWED" => allowed, "BLOCKED" => blocked},
          timeout_ms: 2_000,
          metadata: %{workspace: allowed}
        }

      policy = seatbelt_policy(write_roots: [allowed])

      assert {:error, result} = Exec.run(command, policy)
      assert result.status == :exit
      assert File.read!(Path.join(allowed, "out.txt")) == "ok"
      refute File.exists?(Path.join(blocked, "out.txt"))
    end
  end

  test "seatbelt blocks protected read paths", %{
    seatbelt?: seatbelt?,
    allowed: allowed,
    blocked: blocked
  } do
    if seatbelt? do
      protected = Path.join(blocked, "secret.txt")
      File.write!(protected, "secret")

      command =
        %Command{
          program: "cat",
          args: [protected],
          cwd: File.cwd!(),
          timeout_ms: 2_000,
          metadata: %{workspace: allowed}
        }

      policy = seatbelt_policy(write_roots: [allowed], protected_paths: [protected])

      assert {:error, result} = Exec.run(command, policy)
      assert result.status == :exit
      assert result.stdout =~ "Operation not permitted"
    end
  end

  test "seatbelt profile uses the fixed system executable", %{
    seatbelt?: seatbelt?,
    allowed: allowed
  } do
    if seatbelt? do
      command = %Command{program: "/bin/echo", args: ["hi"], cwd: File.cwd!(), timeout_ms: 1_000}

      assert {:ok, wrapped} = Seatbelt.wrap(command, seatbelt_policy(write_roots: [allowed]))
      assert wrapped.program == "/usr/bin/sandbox-exec"
      assert ["-p", profile, "--", "/bin/echo", "hi"] = wrapped.args
      assert profile =~ "(deny default)"
      assert profile =~ "(allow file-write*"
    end
  end

  defp seatbelt_policy(opts) do
    write_roots = Keyword.get(opts, :write_roots, [])
    protected_paths = Keyword.get(opts, :protected_paths, [])

    %Policy{
      enabled: true,
      backend: :seatbelt,
      mode: :workspace_write,
      network: :restricted,
      filesystem: Enum.map(write_roots, &%{path: {:path, &1}, access: :write}),
      protected_paths: protected_paths,
      protected_names: [".git", ".agents", ".codex"],
      env_allowlist: ["PATH"],
      raw: %{}
    }
  end
end
