defmodule Nex.Agent.AdminTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Admin, Audit, Bus, CodeUpgrade, RequestTrace, Session, Skills, Workspace}
  alias Nex.Agent.Tool.CustomTools

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-admin-#{System.unique_integer([:positive])}")

    Workspace.ensure!(workspace: workspace)

    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    on_exit(fn ->
      Bus.unsubscribe(:admin_events)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "sessions_state and overview_state tolerate empty sessions and sort by updated_at", %{
    workspace: workspace
  } do
    empty_session =
      Session.new("empty-session")
      |> put_session_timestamps(~N[2026-03-29 12:00:00])

    older_session =
      Session.new("older-session")
      |> Session.add_message("user", "older message")
      |> put_session_timestamps(~N[2026-03-29 10:00:00])

    assert :ok = Session.save(empty_session, workspace: workspace)
    assert :ok = Session.save(older_session, workspace: workspace)

    sessions_state = Admin.sessions_state(workspace: workspace)
    overview_state = Admin.overview_state(workspace: workspace)

    assert Enum.map(sessions_state.sessions, & &1.key) == ["empty-session", "older-session"]
    assert sessions_state.selected_session.key == "empty-session"
    assert sessions_state.selected_session.total_messages == 0

    assert Enum.map(overview_state.recent_sessions, & &1.key) == [
             "empty-session",
             "older-session"
           ]

    assert Enum.at(overview_state.recent_sessions, 0).last_message == nil
  end

  test "sessions_state preserves real session keys from metadata", %{workspace: workspace} do
    session =
      Session.new("telegram:123")
      |> Session.add_message("user", "hello from telegram")
      |> put_session_timestamps(~N[2026-03-30 09:00:00])

    assert :ok = Session.save(session, workspace: workspace)

    sessions_state = Admin.sessions_state(workspace: workspace)
    overview_state = Admin.overview_state(workspace: workspace)

    assert Enum.map(sessions_state.sessions, & &1.key) == ["telegram:123"]
    assert sessions_state.selected_session.key == "telegram:123"
    refute Enum.any?(sessions_state.sessions, &(&1.key == "telegram_123"))

    assert Enum.map(overview_state.recent_sessions, & &1.key) == ["telegram:123"]
  end

  test "skills_state and overview_state skip malformed runtime run logs", %{workspace: workspace} do
    runs_dir = Path.join(workspace, "skill_runtime/runs")
    File.mkdir_p!(runs_dir)

    File.write!(Path.join(runs_dir, "broken.jsonl"), "{bad json}\n")

    mixed_lines = [
      Jason.encode!(%{
        "type" => "run_started",
        "run_id" => "run-123",
        "prompt" => "select tools",
        "inserted_at" => "2026-03-30T12:00:00Z"
      }),
      "{bad json}",
      Jason.encode!(%{
        "type" => "skills_selected",
        "run_id" => "run-123",
        "packages" => ["core.weather"],
        "inserted_at" => "2026-03-30T12:00:01Z"
      }),
      Jason.encode!(%{
        "type" => "run_completed",
        "run_id" => "run-123",
        "status" => "ok",
        "result" => "done",
        "inserted_at" => "2026-03-30T12:00:02Z"
      })
    ]

    File.write!(Path.join(runs_dir, "mixed.jsonl"), Enum.join(mixed_lines, "\n"))

    skills_state = Admin.skills_state(workspace: workspace)
    overview_state = Admin.overview_state(workspace: workspace)

    assert length(skills_state.recent_runs) == 1

    assert hd(skills_state.recent_runs) == %{
             run_id: "run-123",
             prompt: "select tools",
             inserted_at: "2026-03-30T12:00:00Z",
             status: "ok",
             result: "done",
             packages: ["core.weather"]
           }

    assert overview_state.skills.recent_runs == 1
  end

  test "runtime_state exposes request trace summaries and selected trace detail", %{
    workspace: workspace
  } do
    trace_opts = [workspace: workspace, request_trace: %{"dir" => "audit/request_traces"}]
    trace_path = RequestTrace.trace_path("run_trace_admin", trace_opts)
    File.mkdir_p!(Path.dirname(trace_path))

    File.write!(
      trace_path,
      [
        Jason.encode!(%{
          "type" => "request_started",
          "run_id" => "run_trace_admin",
          "prompt" => "show me trace",
          "channel" => "telegram",
          "chat_id" => "123",
          "selected_packages" => [%{"name" => "agent-browser"}],
          "inserted_at" => "2026-03-30T12:00:00Z"
        }),
        "{bad json}",
        Jason.encode!(%{
          "type" => "llm_response",
          "run_id" => "run_trace_admin",
          "iteration" => 1,
          "content" => "ok",
          "inserted_at" => "2026-03-30T12:00:01Z"
        }),
        Jason.encode!(%{
          "type" => "tool_result",
          "run_id" => "run_trace_admin",
          "tool" => "list_dir",
          "content" => "done",
          "inserted_at" => "2026-03-30T12:00:02Z"
        }),
        Jason.encode!(%{
          "type" => "request_completed",
          "run_id" => "run_trace_admin",
          "status" => "completed",
          "result" => "final answer",
          "inserted_at" => "2026-03-30T12:00:03Z"
        })
      ]
      |> Enum.join("\n")
    )

    state =
      Admin.runtime_state(
        workspace: workspace,
        trace: "run_trace_admin",
        config_path: Path.join(workspace, "config.json")
      )

    assert state.request_trace_config["enabled"] == false
    assert length(state.recent_request_traces) == 1

    assert hd(state.recent_request_traces) == %{
             run_id: "run_trace_admin",
             prompt: "show me trace",
             inserted_at: "2026-03-30T12:00:00Z",
             status: "completed",
             result: "final answer",
             tool_count: 1,
             llm_rounds: 1,
             selected_packages: [%{"name" => "agent-browser"}],
             used_tools: ["list_dir"],
             skill_call_count: 0
           }

    assert state.selected_request_trace.run_id == "run_trace_admin"
    assert state.selected_request_trace.channel == "telegram"
    assert state.selected_request_trace.chat_id == "123"
    assert state.selected_request_trace.tool_count == 1
    assert state.selected_request_trace.llm_rounds == 1
    assert length(state.selected_request_trace.events) == 4
    assert state.selected_request_trace.used_tools == ["list_dir"]
    assert state.selected_request_trace.available_tools == []
    assert length(state.selected_request_trace.tool_activity) == 1
    assert hd(state.selected_request_trace.tool_activity).name == "list_dir"
    assert length(state.selected_request_trace.llm_turns) == 1
  end

  test "console-facing admin states keep the key fields used by panels", %{workspace: workspace} do
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n- stay layered\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n- likes structured consoles\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# MEMORY\n- keep stable facts here\n")

    session =
      Session.new("qa:console")
      |> Session.add_message("user", "first")
      |> Session.add_message("assistant", "second")

    assert :ok = Session.save(session, workspace: workspace)

    assert :ok =
             Nex.Agent.Evolution.record_signal(
               %{source: :qa, signal: "needs triage", context: %{layer: "MEMORY"}},
               workspace: workspace
             )

    overview_state = Admin.overview_state(workspace: workspace)
    evolution_state = Admin.evolution_state(workspace: workspace)
    memory_state = Admin.memory_state(workspace: workspace)
    sessions_state = Admin.sessions_state(workspace: workspace)

    assert length(overview_state.pending_signals) == 1
    assert length(evolution_state.pending_signals) == 1
    assert memory_state.memory_preview =~ "# MEMORY"
    assert memory_state.memory_bytes > 0
    assert sessions_state.selected_session.last_consolidated == 0
    assert sessions_state.selected_session.unconsolidated_messages == 2
  end

  test "audit append broadcasts normalized admin event", %{workspace: workspace} do
    assert :ok = Admin.subscribe_events(self())

    assert :ok =
             Audit.append("runtime.gateway_started", %{"source" => "test"}, workspace: workspace)

    assert_receive {:bus_message, :admin_events, event}
    assert event["topic"] == "runtime"
    assert event["kind"] == "runtime.gateway_started"
    assert event["summary"] == "Gateway started"
    assert event["payload"] == %{"source" => "test"}
  end

  test "code upgrade source path resolves project source files" do
    path = CodeUpgrade.source_path(Nex.Agent.Admin)

    assert File.exists?(path)
    assert String.ends_with?(path, "/lib/nex/agent/admin.ex")
  end

  test "code_state includes custom tool modules and reads their source" do
    custom_tools_path =
      Path.join(System.tmp_dir!(), "nex-agent-custom-tools-#{System.unique_integer([:positive])}")

    previous_custom_tools_path = Application.get_env(:nex_agent, :custom_tools_path)
    Application.put_env(:nex_agent, :custom_tools_path, custom_tools_path)

    on_exit(fn ->
      if previous_custom_tools_path do
        Application.put_env(:nex_agent, :custom_tools_path, previous_custom_tools_path)
      else
        Application.delete_env(:nex_agent, :custom_tools_path)
      end

      File.rm_rf!(custom_tools_path)
    end)

    tool_name = "console_probe"
    tool_module = "Nex.Agent.Tool.Custom.ConsoleProbe"
    tool_dir = Path.join(custom_tools_path, tool_name)
    File.mkdir_p!(tool_dir)

    File.write!(
      Path.join(tool_dir, "tool.json"),
      Jason.encode!(%{
        "name" => tool_name,
        "module" => tool_module,
        "description" => "Console probe"
      })
    )

    File.write!(
      Path.join(tool_dir, "tool.ex"),
      """
      defmodule #{tool_module} do
        @behaviour Nex.Agent.Tool.Behaviour

        def name, do: "#{tool_name}"
        def definition, do: %{"name" => "#{tool_name}"}
        def execute(_args, _context), do: {:ok, %{"status" => "ok"}}
      end
      """
    )

    state = Admin.code_state()
    selected = Admin.code_state(module: tool_module)

    assert tool_module in state.modules
    assert selected.selected_module == tool_module
    assert selected.current_source =~ "defmodule #{tool_module} do"
    assert selected.current_source_preview =~ "defmodule #{tool_module} do"

    assert CodeUpgrade.source_path(CustomTools.module_for_name(tool_name)) ==
             Path.join(tool_dir, "tool.ex")
  end

  test "publish_draft_skill republishes local and runtime copies", %{workspace: workspace} do
    assert {:ok, _} =
             Skills.create(
               %{
                 name: "draft_probe",
                 description: "[Draft] Probe stuck states",
                 content: "<!-- status: draft, source: evolution -->\n\n# Draft Probe\n",
                 user_invocable: false
               },
               workspace: workspace
             )

    runtime_dir = Path.join(workspace, "skills/rt__draft_probe")
    File.mkdir_p!(runtime_dir)

    File.write!(
      Path.join(runtime_dir, "SKILL.md"),
      """
      ---
      name: "draft_probe"
      description: "[Draft] Probe stuck states"
      user-invocable: false
      execution_mode: knowledge
      ---

      <!-- status: draft, source: evolution -->

      # Draft Probe
      """
    )

    File.write!(
      Path.join(runtime_dir, "source.json"),
      Jason.encode!(%{"source_type" => "legacy_local", "active" => true}, pretty: true)
    )

    assert {:ok, published} = Admin.publish_draft_skill("draft_probe", workspace: workspace)
    refute published.draft
    assert published.display_description == "Probe stuck states"

    skill_file = Path.join(workspace, "skills/draft_probe/SKILL.md")
    runtime_file = Path.join(runtime_dir, "SKILL.md")

    refute File.read!(skill_file) =~ "[Draft]"
    refute File.read!(skill_file) =~ "status: draft"
    assert File.read!(skill_file) =~ "user-invocable: true"

    refute File.read!(runtime_file) =~ "[Draft]"
    refute File.read!(runtime_file) =~ "status: draft"
    assert File.read!(runtime_file) =~ "user-invocable: true"

    state = Admin.skills_state(workspace: workspace)
    assert Enum.any?(state.local_skills, &(&1.name == "draft_probe" and &1.draft == false))

    assert Enum.any?(state.runtime_packages, fn package ->
             package["name"] == "draft_probe" and package["draft"] == false and
               package["active"] == true
           end)
  end

  defp put_session_timestamps(session, naive_datetime) do
    timestamp = DateTime.from_naive!(naive_datetime, "Etc/UTC")
    %{session | created_at: timestamp, updated_at: timestamp}
  end
end
