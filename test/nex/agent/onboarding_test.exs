defmodule Nex.Agent.OnboardingTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Onboarding

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "nex_agent_onboarding_test_#{System.unique_integer([:positive])}")
    base_dir = Path.join(tmp_dir, "agent")
    config_path = Path.join(base_dir, "config.json")

    File.mkdir_p!(base_dir)

    original_base_dir = Application.get_env(:nex_agent, :agent_base_dir)
    original_config_path = Application.get_env(:nex_agent, :config_path)

    Application.put_env(:nex_agent, :agent_base_dir, base_dir)
    Application.put_env(:nex_agent, :config_path, config_path)

    on_exit(fn ->
      if original_base_dir == nil,
        do: Application.delete_env(:nex_agent, :agent_base_dir),
        else: Application.put_env(:nex_agent, :agent_base_dir, original_base_dir)

      if original_config_path == nil,
        do: Application.delete_env(:nex_agent, :config_path),
        else: Application.put_env(:nex_agent, :config_path, original_config_path)

      File.rm_rf!(tmp_dir)
    end)

    %{base_dir: base_dir}
  end

  test "ensure_initialized removes legacy bundled skills and installs markdown bundle", %{base_dir: base_dir} do
    legacy_skills_dir = Path.join([base_dir, "workspace", "skills"])
    File.mkdir_p!(Path.join(legacy_skills_dir, "find-skills"))
    File.mkdir_p!(Path.join(legacy_skills_dir, "browser-mcp"))
    File.write!(Path.join([legacy_skills_dir, "find-skills", "SKILL.md"]), "old")
    File.write!(Path.join([legacy_skills_dir, "browser-mcp", "SKILL.md"]), "old")

    :ok = Onboarding.ensure_initialized()

    refute File.exists?(Path.join(legacy_skills_dir, "find-skills"))
    refute File.exists?(Path.join(legacy_skills_dir, "browser-mcp"))

    bundled_skill = Path.join([legacy_skills_dir, "code-review", "SKILL.md"])
    assert File.exists?(bundled_skill)
    assert File.read!(bundled_skill) =~ "name: code-review"
    assert File.dir?(Path.join([base_dir, "workspace", "tools"]))
  end

  test "ensure_initialized migrates legacy global tools into workspace tools", %{base_dir: base_dir} do
    legacy_tool_dir = Path.join([base_dir, "tools", "hello_tool"])
    File.mkdir_p!(legacy_tool_dir)
    File.write!(Path.join(legacy_tool_dir, "tool.ex"), "defmodule Legacy.Tool do end")
    File.write!(Path.join(legacy_tool_dir, "tool.json"), "{}")

    :ok = Onboarding.ensure_initialized()

    refute File.exists?(Path.join(base_dir, "tools"))
    assert File.exists?(Path.join([base_dir, "workspace", "tools", "hello_tool", "tool.ex"]))
    assert File.exists?(Path.join([base_dir, "workspace", "tools", "hello_tool", "tool.json"]))
  end
end
