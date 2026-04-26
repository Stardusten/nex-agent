defmodule Nex.Agent.RuntimeTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Config, Runtime, Skills}
  alias Nex.Agent.Runtime.Snapshot

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-runtime-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "hooks"))
    File.mkdir_p!(Path.join(workspace, "skills/always-guide"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\nRuntime AGENTS layer.\n")
    File.write!(Path.join(workspace, "IDENTITY.md"), "# Identity\nRuntime identity layer.\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\nRuntime SOUL layer.\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\nRuntime USER layer.\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\nRuntime TOOLS layer.\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\nRuntime memory.\n")

    File.write!(
      Path.join(workspace, "hooks/hooks.json"),
      Jason.encode!(%{
        "version" => 1,
        "hooks" => [
          %{
            "id" => "runtime-test",
            "event" => "prompt.build.before",
            "pointcut" => %{"session" => "discord:test"},
            "advice" => %{"kind" => "text", "content" => "Runtime hook context."}
          }
        ]
      })
    )

    File.write!(
      Path.join(workspace, "skills/always-guide/SKILL.md"),
      """
      ---
      name: always-guide
      description: Always loaded test guide.
      always: true
      ---

      Runtime always skill instruction.
      """
    )

    previous_workspace = Application.get_env(:nex_agent, :workspace_path)
    Application.put_env(:nex_agent, :workspace_path, workspace)
    Skills.load()

    Runtime.reload(workspace: workspace, changed_paths: [])

    on_exit(fn ->
      restore_env(:workspace_path, previous_workspace)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "initial snapshot is readable and includes prompt tools and skills", %{
    workspace: workspace
  } do
    assert {:ok, %Snapshot{} = snapshot} = Runtime.current()

    assert snapshot.version >= 1
    assert snapshot.workspace == workspace
    assert %Config{} = snapshot.config
    assert snapshot.prompt.system_prompt =~ "Runtime AGENTS layer."
    assert snapshot.prompt.system_prompt =~ "Runtime identity layer."
    assert is_list(snapshot.prompt.diagnostics)
    assert is_binary(snapshot.prompt.hash)
    assert snapshot.commands.definitions != []
    assert Enum.any?(snapshot.commands.definitions, &(&1["name"] == "new"))
    assert Enum.any?(snapshot.commands.definitions, &(&1["name"] == "commands"))
    assert is_binary(snapshot.commands.hash)
    assert snapshot.tools.definitions_all != []
    assert snapshot.tools.definitions_subagent != []
    assert snapshot.tools.definitions_cron != []
    assert is_binary(snapshot.tools.hash)
    assert Map.has_key?(snapshot.subagents.profiles, "general")
    assert Enum.any?(snapshot.subagents.definitions, &(&1["name"] == "code_reviewer"))
    assert is_binary(snapshot.subagents.hash)
    assert snapshot.skills.always_instructions =~ "Runtime always skill instruction."
    assert is_binary(snapshot.skills.hash)
    assert Enum.any?(snapshot.hooks.entries, &(Map.get(&1, "id") == "runtime-test"))
    assert snapshot.hooks.diagnostics == []
    assert is_binary(snapshot.hooks.hash)
  end

  test "snapshot channels are keyed by channel instance id", %{workspace: workspace} do
    config = runtime_config(workspace)

    assert {:ok, %Snapshot{} = snapshot} =
             Runtime.reload(workspace: workspace, config_loader: fn _opts -> config end)

    assert snapshot.channels == %{
             "feishu_kai" => %{"type" => "feishu", "streaming" => true},
             "discord_kai" => %{
               "type" => "discord",
               "streaming" => false,
               "show_table_as" => "ascii"
             }
           }
  end

  test "tool definition builder receives resolved default model runtime", %{workspace: workspace} do
    parent = self()
    config = runtime_config(workspace)

    tool_builder = fn filter, opts ->
      send(parent, {:tool_definition_opts, filter, Keyword.fetch!(opts, :model_runtime)})
      []
    end

    assert {:ok, %Snapshot{}} =
             Runtime.reload(
               workspace: workspace,
               config_loader: fn _opts -> config end,
               tool_definitions_builder: tool_builder
             )

    for filter <- [:all, :follow_up, :subagent, :cron] do
      assert_receive {:tool_definition_opts, ^filter,
                      %{
                        model_key: "hy3-preview",
                        model_id: "hy3-preview",
                        provider_key: "hy3-tencent",
                        provider_type: "openai-compatible",
                        provider: :openai,
                        api_key: "sk-runtime-test"
                      }}
    end
  end

  test "runtime loads workspace subagent profiles and passes them to tool definitions", %{
    workspace: workspace
  } do
    File.mkdir_p!(Path.join(workspace, "subagents"))

    File.write!(
      Path.join(workspace, "subagents/debugger.md"),
      """
      ---
      name: debugger
      description: Diagnose failures with read-only tools.
      model_role: advisor
      tools_filter: follow_up
      ---

      You are a debugger. Explain the likely root cause before suggesting a fix.
      """
    )

    parent = self()

    tool_builder = fn filter, opts ->
      profiles = Keyword.fetch!(opts, :subagent_profiles)
      send(parent, {:profiles, filter, Map.keys(profiles) |> Enum.sort()})
      []
    end

    assert {:ok, %Snapshot{} = snapshot} =
             Runtime.reload(workspace: workspace, tool_definitions_builder: tool_builder)

    assert snapshot.subagents.profiles["debugger"].prompt =~ "You are a debugger."
    assert Enum.any?(snapshot.subagents.definitions, &(&1["name"] == "debugger"))

    assert_receive {:profiles, :all, names}
    assert "debugger" in names
    assert "general" in names

    old_hash = snapshot.subagents.hash
    old_definitions = snapshot.subagents.definitions

    File.write!(
      Path.join(workspace, "subagents/debugger.md"),
      """
      ---
      name: debugger
      description: Diagnose failures with read-only tools.
      model_role: advisor
      tools_filter: follow_up
      ---

      You are a debugger. Start with the smallest reproducible signal.
      """
    )

    assert {:ok, %Snapshot{} = updated} =
             Runtime.reload(workspace: workspace, tool_definitions_builder: tool_builder)

    assert updated.subagents.definitions == old_definitions
    assert updated.subagents.hash != old_hash
  end

  test "reload succeeds, increments version, broadcasts event, and records changed paths", %{
    workspace: workspace
  } do
    assert {:ok, before_snapshot} = Runtime.current()
    assert :ok = Runtime.subscribe()

    assert {:ok, %Snapshot{} = after_snapshot} =
             Runtime.reload(workspace: workspace, changed_paths: ["SOUL.md"])

    assert after_snapshot.version == before_snapshot.version + 1
    assert after_snapshot.changed_paths == ["SOUL.md"]

    assert_receive {:runtime_updated,
                    %{
                      old_version: old_version,
                      new_version: new_version,
                      changed_paths: ["SOUL.md"]
                    }}

    assert old_version == before_snapshot.version
    assert new_version == after_snapshot.version
    assert Runtime.current_version() == after_snapshot.version
  end

  test "reload failure does not replace last valid snapshot", %{workspace: workspace} do
    assert {:ok, before_snapshot} = Runtime.current()

    assert {:error, :prompt_failed} =
             Runtime.reload(
               workspace: workspace,
               prompt_builder: fn _opts -> {:error, :prompt_failed} end
             )

    assert {:ok, after_snapshot} = Runtime.current()
    assert after_snapshot.version == before_snapshot.version
    assert after_snapshot.prompt.hash == before_snapshot.prompt.hash
  end

  test "workspace resolver prefers explicit option over application workspace", %{
    workspace: app_workspace
  } do
    explicit_workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-runtime-explicit-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(explicit_workspace, "memory"))
    File.write!(Path.join(explicit_workspace, "AGENTS.md"), "# AGENTS\nExplicit workspace.\n")
    File.write!(Path.join(explicit_workspace, "memory/MEMORY.md"), "# Memory\n")

    on_exit(fn -> File.rm_rf!(explicit_workspace) end)

    assert {:ok, snapshot} = Runtime.reload(workspace: explicit_workspace)

    assert snapshot.workspace == explicit_workspace
    assert snapshot.workspace != app_workspace
    assert snapshot.prompt.system_prompt =~ "Explicit workspace."
  end

  test "runtime initial snapshot can read already-started skills and tool registry", %{
    workspace: workspace
  } do
    name = :"runtime_dependency_test_#{System.unique_integer([:positive])}"

    assert {:ok, pid} = Runtime.start_link(name: name, workspace: workspace)

    snapshot = :sys.get_state(pid).snapshot
    assert snapshot.skills.always_instructions =~ "Runtime always skill instruction."
    assert Enum.any?(snapshot.tools.definitions_all, &(&1["name"] == "read"))

    GenServer.stop(pid)
  end

  test "version 1 snapshot build failure fails fast" do
    name = :"runtime_fail_fast_test_#{System.unique_integer([:positive])}"
    previous_flag = Process.flag(:trap_exit, true)

    assert {:error, {:snapshot_build_failed, :boom}} =
             Runtime.start_link(name: name, prompt_builder: fn _opts -> {:error, :boom} end)

    Process.flag(:trap_exit, previous_flag)
  end

  defp runtime_config(workspace) do
    Config.from_map(%{
      "max_iterations" => 100,
      "workspace" => workspace,
      "channel" => %{
        "feishu_kai" => %{
          "type" => "feishu",
          "enabled" => true,
          "streaming" => true,
          "app_id" => "cli_feishu_app",
          "app_secret" => "feishu_secret"
        },
        "discord_kai" => %{
          "type" => "discord",
          "enabled" => true,
          "streaming" => false,
          "token" => "discord-token"
        }
      },
      "gateway" => %{"port" => 18_790},
      "provider" => %{
        "providers" => %{
          "hy3-tencent" => %{
            "type" => "openai-compatible",
            "base_url" => "https://hy3.example.com/v1",
            "api_key" => "sk-runtime-test"
          }
        }
      },
      "model" => %{
        "cheap_model" => "hy3-preview",
        "default_model" => "hy3-preview",
        "advisor_model" => "hy3-preview",
        "models" => %{
          "hy3-preview" => %{"provider" => "hy3-tencent", "id" => "hy3-preview"}
        }
      },
      "tools" => %{}
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:nex_agent, key)
  defp restore_env(key, value), do: Application.put_env(:nex_agent, key, value)
end
