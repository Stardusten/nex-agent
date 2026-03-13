defmodule Nex.Agent.UpgradeManagerTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.UpgradeManager

  test "git_trackable_source_path returns relative path for repo file" do
    repo_root = File.cwd!()
    source_path = Path.join(repo_root, "lib/nex/agent/runner.ex")

    assert {:ok, relative_path} = UpgradeManager.git_trackable_source_path(source_path, repo_root)
    assert relative_path == "lib/nex/agent/runner.ex"
  end

  test "git_trackable_source_path skips source outside repo" do
    repo_root = File.cwd!()
    tmp_path = Path.join(System.tmp_dir!(), "nex-agent-upgrade-manager-outside.ex")
    on_exit(fn -> File.rm(tmp_path) end)
    File.write!(tmp_path, "defmodule TmpOutside do\nend\n")

    assert {:skip, reason} = UpgradeManager.git_trackable_source_path(tmp_path, repo_root)
    assert reason =~ "outside git repo"
  end

  test "git_trackable_source_path skips missing file" do
    repo_root = File.cwd!()
    missing_path = Path.join(System.tmp_dir!(), "nex-agent-upgrade-manager-missing.ex")

    assert {:skip, reason} = UpgradeManager.git_trackable_source_path(missing_path, repo_root)
    assert reason =~ "does not exist"
  end
end
