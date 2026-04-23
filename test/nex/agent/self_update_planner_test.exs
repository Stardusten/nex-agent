defmodule Nex.Agent.SelfUpdate.PlannerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.SelfUpdate.Planner

  setup do
    repo_root =
      Path.join(System.tmp_dir!(), "nex-agent-planner-#{System.unique_integer([:positive])}")

    previous_repo_root = Application.get_env(:nex_agent, :repo_root)
    File.mkdir_p!(repo_root)
    Application.put_env(:nex_agent, :repo_root, repo_root)

    on_exit(fn ->
      if previous_repo_root do
        Application.put_env(:nex_agent, :repo_root, previous_repo_root)
      else
        Application.delete_env(:nex_agent, :repo_root)
      end

      File.rm_rf!(repo_root)
    end)

    {:ok, repo_root: repo_root}
  end

  test "pending_code_files returns only tracked CODE-layer changes", %{repo_root: repo_root} do
    code_path = Path.join(repo_root, "lib/nex/agent/sample.ex")
    test_path = Path.join(repo_root, "test/nex/agent/sample_test.exs")
    readme_path = Path.join(repo_root, "README.md")

    File.mkdir_p!(Path.dirname(code_path))
    File.mkdir_p!(Path.dirname(test_path))
    File.write!(code_path, "defmodule Nex.Agent.Sample do\n  def value, do: :v1\nend\n")
    File.write!(test_path, "defmodule Nex.Agent.SampleTest do\n  use ExUnit.Case\nend\n")
    File.write!(readme_path, "baseline\n")

    git!(repo_root, ["init"])
    git!(repo_root, ["config", "user.email", "planner@example.com"])
    git!(repo_root, ["config", "user.name", "Planner Test"])
    git!(repo_root, ["add", "."])
    git!(repo_root, ["commit", "-m", "init"])

    File.write!(code_path, "defmodule Nex.Agent.Sample do\n  def value, do: :v2\nend\n")
    File.write!(readme_path, "changed\n")

    assert {:ok, [pending_file], []} = Planner.pending_code_files()
    assert pending_file == code_path
  end

  test "pending_code_files returns a git error outside a repository" do
    assert {:error, message} = Planner.pending_code_files()
    assert message =~ "Unable to inspect pending CODE files via git status"
  end

  test "plan deduplicates files and resolves related tests", %{repo_root: repo_root} do
    code_path = Path.join(repo_root, "lib/nex/agent/sample.ex")
    test_path = Path.join(repo_root, "test/nex/agent/sample_test.exs")

    File.mkdir_p!(Path.dirname(code_path))
    File.mkdir_p!(Path.dirname(test_path))
    File.write!(code_path, "defmodule Nex.Agent.Sample do\n  def value, do: :ok\nend\n")
    File.write!(test_path, "defmodule Nex.Agent.SampleTest do\n  use ExUnit.Case\nend\n")

    assert {:ok, [entry], []} = Planner.plan([code_path, code_path])
    assert entry.path == code_path
    assert entry.relative_path == "lib/nex/agent/sample.ex"
    assert entry.module == Nex.Agent.Sample
    assert entry.module_name == "Nex.Agent.Sample"
    assert entry.test == test_path
  end

  test "plan rejects protected modules", %{repo_root: repo_root} do
    path = Path.join(repo_root, "lib/nex/agent/self_update/planner.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "defmodule Nex.Agent.SelfUpdate.Planner do\nend\n")

    assert {:error, message} = Planner.plan([path])
    assert message =~ "Protected module cannot be deployed via self_update"
  end

  test "plan rejects CODE-layer files without a module definition", %{repo_root: repo_root} do
    path = Path.join(repo_root, "lib/nex/agent/no_module.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "IO.puts(:missing_module)\n")

    assert {:error, "Could not detect module name in source file"} = Planner.plan([path])
  end

  defp git!(repo_root, args) do
    case System.cmd("git", args, cd: repo_root, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
