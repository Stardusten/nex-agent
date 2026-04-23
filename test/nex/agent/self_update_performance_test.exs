defmodule Nex.Agent.SelfUpdatePerformanceTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.SelfUpdate.Deployer

  setup do
    repo_root =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-self-update-perf-#{System.unique_integer([:positive])}"
      )

    previous_repo_root = Application.get_env(:nex_agent, :repo_root)
    previous_path = System.get_env("PATH") || ""
    fake_bin = Path.join(repo_root, "fake-bin")
    mix_log = Path.join(repo_root, "mix.log")

    File.mkdir_p!(fake_bin)
    File.mkdir_p!(Path.join(repo_root, "lib/nex/agent"))
    File.mkdir_p!(Path.join(repo_root, "test/nex/agent"))

    File.write!(
      Path.join(fake_bin, "mix"),
      """
      #!/bin/sh
      echo "__CALL__" >> "#{mix_log}"
      printf '%s\n' "$@" >> "#{mix_log}"
      exit 0
      """
    )

    File.chmod!(Path.join(fake_bin, "mix"), 0o755)
    System.put_env("PATH", fake_bin <> ":" <> previous_path)
    Application.put_env(:nex_agent, :repo_root, repo_root)

    on_exit(fn ->
      System.put_env("PATH", previous_path)

      if previous_repo_root do
        Application.put_env(:nex_agent, :repo_root, previous_repo_root)
      else
        Application.delete_env(:nex_agent, :repo_root)
      end

      File.rm_rf!(repo_root)
    end)

    {:ok, repo_root: repo_root, mix_log: mix_log}
  end

  test "related tests run as one mix test plan", %{repo_root: repo_root, mix_log: mix_log} do
    alpha_source = Path.join(repo_root, "lib/nex/agent/alpha.ex")
    beta_source = Path.join(repo_root, "lib/nex/agent/beta.ex")
    alpha_test = Path.join(repo_root, "test/nex/agent/alpha_test.exs")
    beta_test = Path.join(repo_root, "test/nex/agent/beta_test.exs")

    File.write!(alpha_source, "defmodule Nex.Agent.Alpha do\n  def value, do: :one\nend\n")
    File.write!(beta_source, "defmodule Nex.Agent.Beta do\n  def value, do: :two\nend\n")
    File.write!(alpha_test, "defmodule Nex.Agent.AlphaTest do\n  use ExUnit.Case\nend\n")
    File.write!(beta_test, "defmodule Nex.Agent.BetaTest do\n  use ExUnit.Case\nend\n")

    Code.compile_file(alpha_source)
    Code.compile_file(beta_source)

    File.write!(
      alpha_source,
      "defmodule Nex.Agent.Alpha do\n  def value, do: :one_updated\nend\n"
    )

    File.write!(beta_source, "defmodule Nex.Agent.Beta do\n  def value, do: :two_updated\nend\n")

    assert %{status: :deployed, tests: tests} =
             Deployer.deploy("single test invocation", [alpha_source, beta_source])

    assert Enum.sort(tests) ==
             Enum.sort([
               %{path: alpha_test, status: :passed},
               %{path: beta_test, status: :passed}
             ])

    log =
      mix_log
      |> File.read!()
      |> String.split("\n", trim: true)

    assert Enum.count(log, &(&1 == "__CALL__")) == 1

    assert log == [
             "__CALL__",
             "test",
             "test/nex/agent/alpha_test.exs",
             "test/nex/agent/beta_test.exs"
           ]
  end
end
