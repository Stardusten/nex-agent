defmodule Nex.Agent.Self.EvolutionTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Self.Evolution, Capability.Skills, Runtime.Workspace}
  alias Nex.Agent.Observe.ControlPlane.{Gauge, Log, Query, Store}
  alias Nex.Agent.Tool.EvolutionCandidate
  require Log
  require Gauge

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-evolution-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    File.write!(Path.join(workspace, "SOUL.md"), "# Soul\n\n## Values\n- Be helpful\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n- likes concise replies\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\nStable facts live here.\n")

    File.write!(
      Path.join(workspace, "memory/HISTORY.md"),
      "[2026-03-20 10:00] historical note.\n"
    )

    Application.put_env(:nex_agent, :workspace_path, workspace)

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Skills) == nil do
      start_supervised!({Skills, []})
    end

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  describe "record_signal/2" do
    test "writes evolution.signal.recorded to ControlPlane only", %{workspace: workspace} do
      assert :ok =
               Evolution.record_signal(
                 %{
                   source: "runner",
                   signal: "User correction: fix output",
                   context: %{tool_errors: 1}
                 },
                 workspace: workspace
               )

      [signal] = Evolution.recent_signals(workspace: workspace)
      assert signal["tag"] == "evolution.signal.recorded"
      assert signal["attrs_summary"]["source"] == "runner"
      assert signal["attrs_summary"]["signal"] == "User correction: fix output"

      refute File.exists?(Path.join(Workspace.memory_dir(workspace: workspace), "patterns.jsonl"))
    end
  end

  describe "candidate lifecycle reduction" do
    test "derives candidate status from evolution.candidate.* observations", %{
      workspace: workspace
    } do
      assert {:ok, _} =
               Log.info(
                 "evolution.candidate.proposed",
                 %{
                   "id" => "cand_memory",
                   "kind" => "memory_candidate",
                   "summary" => "Persist JSON preference",
                   "rationale" => "Repeated corrections asked for JSON output",
                   "evidence_ids" => ["obs_1", "obs_2"],
                   "risk" => "low",
                   "requires_owner_approval" => true,
                   "created_at" => Store.timestamp(),
                   "trigger" => "manual",
                   "profile" => "routine",
                   "budget_mode" => "normal"
                 },
                 workspace: workspace
               )

      assert {:ok, _} =
               Log.info(
                 "evolution.candidate.approved",
                 %{
                   "candidate_id" => "cand_memory",
                   "mode" => "apply",
                   "decision_reason" => "Looks good"
                 },
                 workspace: workspace
               )

      assert {:ok, _} =
               Log.info(
                 "evolution.candidate.apply.failed",
                 %{
                   "candidate_id" => "cand_memory",
                   "error_summary" => "memory write failed"
                 },
                 workspace: workspace
               )

      assert {:ok, candidate} = Evolution.candidate("cand_memory", workspace: workspace)
      assert candidate["status"] == "failed"
      assert candidate["kind"] == "memory_candidate"
      assert candidate["latest_error"] == "memory write failed"
      assert length(candidate["lifecycle_observation_ids"]) == 3

      assert [%{"candidate_id" => "cand_memory", "status" => "failed"}] =
               Evolution.recent_candidates(workspace: workspace)
    end

    test "superseded lifecycle is derived from observations", %{workspace: workspace} do
      assert {:ok, _} =
               Log.info(
                 "evolution.candidate.proposed",
                 %{
                   "id" => "cand_old",
                   "kind" => "memory_candidate",
                   "summary" => "Persist JSON preference",
                   "rationale" => "old rationale",
                   "evidence_ids" => ["obs_1"],
                   "risk" => "low",
                   "requires_owner_approval" => true,
                   "created_at" => Store.timestamp()
                 },
                 workspace: workspace
               )

      assert {:ok, _} =
               Log.info(
                 "evolution.candidate.superseded",
                 %{
                   "candidate_id" => "cand_old",
                   "superseded_by" => "cand_new",
                   "kind" => "memory_candidate",
                   "summary" => "Persist JSON preference"
                 },
                 workspace: workspace
               )

      assert {:ok, candidate} = Evolution.candidate("cand_old", workspace: workspace)
      assert candidate["status"] == "superseded"
    end
  end

  describe "evolution_candidate tool" do
    test "lists, shows, approves, and rejects candidates through observations", %{
      workspace: workspace
    } do
      assert {:ok, _} =
               Log.info(
                 "evolution.candidate.proposed",
                 %{
                   "id" => "cand_code",
                   "kind" => "code_hint",
                   "summary" => "Tighten retry path",
                   "rationale" => "Repeated tool failures need a bounded plan",
                   "evidence_ids" => ["obs_1"],
                   "risk" => "medium",
                   "requires_owner_approval" => true,
                   "created_at" => Store.timestamp()
                 },
                 workspace: workspace,
                 run_id: "run-1"
               )

      ctx = %{workspace: workspace, run_id: "run-1", session_key: "s1"}

      assert {:ok, %{"candidates" => [%{"candidate_id" => "cand_code", "status" => "pending"}]}} =
               EvolutionCandidate.execute(%{"action" => "list"}, ctx)

      assert {:ok, %{"candidate_id" => "cand_code", "status" => "pending"}} =
               EvolutionCandidate.execute(
                 %{"action" => "show", "candidate_id" => "cand_code"},
                 ctx
               )

      assert {:ok, %{"decision" => "approved", "mode" => "plan"}} =
               EvolutionCandidate.execute(
                 %{"action" => "approve", "candidate_id" => "cand_code"},
                 ctx
               )

      assert {:ok, approved} = Evolution.candidate("cand_code", workspace: workspace)
      assert approved["status"] == "realized"
      assert approved["decided_at"]

      assert {:error, "Candidate already realized; cannot reject"} =
               EvolutionCandidate.execute(
                 %{"action" => "reject", "candidate_id" => "cand_code"},
                 ctx
               )

      assert {:error, "Candidate not found: missing"} =
               EvolutionCandidate.execute(
                 %{"action" => "approve", "candidate_id" => "missing"},
                 ctx
               )
    end

    test "reject writes rejected lifecycle observation for pending candidate", %{
      workspace: workspace
    } do
      assert {:ok, _} =
               Log.info(
                 "evolution.candidate.proposed",
                 %{
                   "id" => "cand_skill",
                   "kind" => "skill_candidate",
                   "summary" => "Capture triage workflow",
                   "rationale" => "The same workflow recurs",
                   "evidence_ids" => ["obs_2"],
                   "risk" => "low",
                   "requires_owner_approval" => true,
                   "created_at" => Store.timestamp()
                 },
                 workspace: workspace
               )

      assert {:ok, %{"decision" => "rejected"}} =
               EvolutionCandidate.execute(
                 %{
                   "action" => "reject",
                   "candidate_id" => "cand_skill",
                   "decision_reason" => "not enough evidence"
                 },
                 %{workspace: workspace}
               )

      assert {:ok, rejected} = Evolution.candidate("cand_skill", workspace: workspace)
      assert rejected["status"] == "rejected"
    end

    test "code_hint apply reuses apply_patch and self_update lanes", %{workspace: workspace} do
      assert {:ok, _} =
               Log.info(
                 "evolution.candidate.proposed",
                 %{
                   "id" => "cand_code_apply",
                   "kind" => "code_hint",
                   "summary" => "Patch lib/nex/agent/example.ex for retry handling",
                   "rationale" =>
                     "Update lib/nex/agent/example.ex to guard retries and redeploy.",
                   "evidence_ids" => ["obs_1"],
                   "risk" => "medium",
                   "requires_owner_approval" => true,
                   "created_at" => Store.timestamp()
                 },
                 workspace: workspace
               )

      parent = self()

      llm_call_fun = fn _messages, _opts ->
        send(parent, :realization_llm_called)

        {:ok,
         %{
           "summary" => "Apply retry guard patch",
           "files" => ["lib/nex/agent/example.ex"],
           "patch" => """
           *** Begin Patch
           *** Update File: lib/nex/agent/example.ex
           @@
           -old
           +new
           *** End Patch
           """,
           "deploy_reason" => "owner approved code hint"
         }}
      end

      apply_patch_fun = fn %{"patch" => patch}, _ctx ->
        send(parent, {:apply_patch_called, patch})
        {:ok, %{"status" => "ok", "updated_files" => ["lib/nex/agent/example.ex"]}}
      end

      self_update_fun = fn %{"action" => "deploy", "files" => files, "reason" => reason}, _ctx ->
        send(parent, {:self_update_called, files, reason})
        {:ok, %{status: :deployed, files: files, release_id: "rel_code"}}
      end

      ctx = %{
        workspace: workspace,
        llm_call_fun: llm_call_fun,
        apply_patch_fun: apply_patch_fun,
        self_update_fun: self_update_fun,
        read_fun: fn %{"path" => path}, _ctx ->
          {:ok, %{"content" => "defmodule Example do\nend\n", "path" => path}}
        end
      }

      assert {:ok,
              %{"decision" => "approved", "mode" => "apply", "apply" => %{"status" => "applied"}}} =
               EvolutionCandidate.execute(
                 %{"action" => "approve", "candidate_id" => "cand_code_apply", "mode" => "apply"},
                 ctx
               )

      assert_receive :realization_llm_called
      assert_receive {:apply_patch_called, patch}
      assert patch =~ "*** Begin Patch"

      assert_receive {:self_update_called, ["lib/nex/agent/example.ex"],
                      "owner approved code hint"}

      assert {:ok, applied} = Evolution.candidate("cand_code_apply", workspace: workspace)
      assert applied["status"] == "applied"
    end
  end

  describe "maybe_trigger_after_consolidation/1" do
    test "counter persists and triggers async evolution at threshold", %{workspace: workspace} do
      write_budget(workspace, 60)
      seed_observations(workspace)

      Enum.each(1..4, fn _ ->
        refute Evolution.maybe_trigger_after_consolidation(workspace: workspace)
      end)

      assert Evolution.maybe_trigger_after_consolidation(
               workspace: workspace,
               llm_call_fun: fn _messages, _opts ->
                 {:ok,
                  %{
                    "observations" => "Routine reflection.",
                    "candidates" => [
                      %{
                        "kind" => "code_hint",
                        "summary" => "Add targeted retry guidance",
                        "rationale" => "Repeated runner/tool failures were observed.",
                        "evidence_ids" =>
                          Evolution.recent_signals(workspace: workspace)
                          |> Enum.map(& &1["id"]),
                        "risk" => "medium"
                      }
                    ]
                  }}
               end
             )

      counter_path = Path.join(Workspace.memory_dir(workspace: workspace), ".evolution_counter")
      assert File.read!(counter_path) |> String.trim() == "5"

      assert wait_until(fn ->
               Enum.any?(Evolution.recent_events(workspace: workspace), fn event ->
                 event["tag"] == "evolution.cycle.completed"
               end)
             end)
    end
  end

  describe "run_evolution_cycle/1" do
    test "sleep budget skips without invoking the LLM", %{workspace: workspace} do
      write_budget(workspace, 0)
      seed_observations(workspace)
      parent = self()

      assert {:ok, result} =
               Evolution.run_evolution_cycle(
                 workspace: workspace,
                 llm_call_fun: fn _messages, _opts ->
                   send(parent, :llm_called)
                   {:ok, %{"observations" => "should not happen", "candidates" => []}}
                 end
               )

      assert result.status == :skipped
      assert result.budget_mode == :sleep
      refute_receive :llm_called

      assert Enum.any?(Evolution.recent_events(workspace: workspace), fn event ->
               event["tag"] == "evolution.cycle.skipped"
             end)
    end

    test "low budget returns cheap reflection candidates without writing files", %{
      workspace: workspace
    } do
      write_budget(workspace, 10)
      seed_observations(workspace)

      soul_before = File.read!(Path.join(workspace, "SOUL.md"))
      memory_before = File.read!(Path.join(workspace, "memory/MEMORY.md"))

      assert {:ok, result} = Evolution.run_evolution_cycle(workspace: workspace)

      assert result.status == :completed
      assert result.budget_mode == :low
      assert result.candidate_count == 1
      assert [%{"kind" => "reflection_candidate"}] = result.candidates
      assert File.read!(Path.join(workspace, "SOUL.md")) == soul_before
      assert File.read!(Path.join(workspace, "memory/MEMORY.md")) == memory_before
    end

    test "normal budget builds evidence pack and returns candidate actions only", %{
      workspace: workspace
    } do
      write_budget(workspace, 60)
      seed_observations(workspace)

      assert {:ok, _} =
               Gauge.set(
                 "run.owner.current",
                 %{"owners" => [%{"run_id" => "run-1", "status" => "running"}]},
                 %{"source" => "test"},
                 workspace: workspace
               )

      assert {:ok, _} =
               Log.info(
                 "evolution.candidate.proposed",
                 %{
                   "id" => "cand_prev",
                   "kind" => "record_only",
                   "summary" => "Older candidate",
                   "rationale" => "Older rationale",
                   "evidence_ids" => ["obs_prev"],
                   "risk" => "low",
                   "requires_owner_approval" => true,
                   "created_at" => Store.timestamp()
                 },
                 workspace: workspace
               )

      soul_before = File.read!(Path.join(workspace, "SOUL.md"))
      memory_before = File.read!(Path.join(workspace, "memory/MEMORY.md"))
      parent = self()

      llm_call_fun = fn messages, _opts ->
        user_message = Enum.find(messages, &(&1["role"] == "user"))
        prompt = user_message["content"]
        send(parent, {:prompt, prompt})

        evidence_ids =
          Query.query(%{"limit" => 20}, workspace: workspace)
          |> Enum.map(& &1["id"])
          |> Enum.take(2)

        {:ok,
         %{
           "observations" => "Repeated tool and HTTP failures.",
           "candidates" => [
             %{
               "kind" => "code_hint",
               "summary" => "Tighten tool failure recovery path",
               "rationale" => "The same failures repeated across recent observations.",
               "evidence_ids" => evidence_ids,
               "risk" => "medium"
             }
           ]
         }}
      end

      assert {:ok, result} =
               Evolution.run_evolution_cycle(
                 workspace: workspace,
                 trigger: :manual,
                 llm_call_fun: llm_call_fun
               )

      assert result == %{
               status: :completed,
               trigger: :manual,
               profile: :routine,
               budget_mode: :normal,
               evidence_count: result.evidence_count,
               pattern_count: result.pattern_count,
               candidate_count: 1,
               candidates: result.candidates
             }

      assert [%{"kind" => "code_hint", "requires_owner_approval" => true} = candidate] =
               result.candidates

      assert result.evidence_count == 4
      assert length(candidate["evidence_ids"]) >= 1
      assert File.read!(Path.join(workspace, "SOUL.md")) == soul_before
      assert File.read!(Path.join(workspace, "memory/MEMORY.md")) == memory_before

      assert_receive {:prompt, prompt}, 500
      assert prompt =~ "\"evolution.signal.recorded\""
      assert prompt =~ "\"budget\""
      assert prompt =~ "\"observations\""
      assert prompt =~ "\"candidate_history\""
      assert prompt =~ "\"current_runs\""

      events = Evolution.recent_events(workspace: workspace)
      tags = Enum.map(events, & &1["tag"])
      assert "evolution.cycle.started" in tags
      assert "evolution.cycle.completed" in tags
      assert "evolution.pattern.detected" in tags
      assert "evolution.candidate.proposed" in tags
    end

    test "budget-gated deep profile records spend failure and skips deeper work", %{
      workspace: workspace
    } do
      write_budget(workspace, 60)
      seed_observations(workspace)

      assert {:ok, result} =
               Evolution.run_evolution_cycle(
                 workspace: workspace,
                 trigger: :scheduled_weekly
               )

      assert result.status == :skipped

      assert Enum.any?(Evolution.recent_events(workspace: workspace), fn event ->
               event["tag"] == "evolution.budget.spend.failed"
             end)
    end

    test "failed evolution cycle is visible in incident queries", %{workspace: workspace} do
      write_budget(workspace, 60)
      seed_observations(workspace)

      assert {:error, {:llm_failed, "boom"}} =
               Evolution.run_evolution_cycle(
                 workspace: workspace,
                 llm_call_fun: fn _messages, _opts -> {:error, "boom"} end
               )

      incident =
        Query.incident(%{"tag" => "evolution.cycle.failed", "limit" => 10}, workspace: workspace)

      assert [%{"tag" => "evolution.cycle.failed", "level" => "error"}] = incident["errors"]
    end
  end

  describe "recent_events/1" do
    test "returns only evolution-tagged observations", %{workspace: workspace} do
      assert {:ok, _} =
               Log.info("evolution.cycle.started", %{"trigger" => "manual"}, workspace: workspace)

      assert {:ok, _} = Log.info("other.event", %{"data" => "test"}, workspace: workspace)

      assert {:ok, _} =
               Log.info(
                 "evolution.candidate.proposed",
                 %{"summary" => "candidate", "evidence_ids" => ["obs_1"]},
                 workspace: workspace
               )

      events = Evolution.recent_events(workspace: workspace)
      assert length(events) == 2
      assert Enum.all?(events, fn event -> String.starts_with?(event["tag"], "evolution.") end)
    end
  end

  defp seed_observations(workspace) do
    Evolution.record_signal(
      %{source: "runner", signal: "Repeated correction", context: %{"tool_name" => "bash"}},
      workspace: workspace
    )

    assert {:ok, _} =
             Log.error(
               "runner.tool.call.failed",
               %{"tool_name" => "bash", "reason_type" => "exit_status"},
               workspace: workspace,
               run_id: "run-1"
             )

    assert {:ok, _} =
             Log.error(
               "runner.tool.call.failed",
               %{"tool_name" => "bash", "reason_type" => "exit_status"},
               workspace: workspace,
               run_id: "run-1"
             )

    assert {:ok, _} =
             Log.warning(
               "http.request.failed",
               %{"reason_type" => "timeout"},
               workspace: workspace,
               run_id: "run-1"
             )
  end

  defp write_budget(workspace, current) do
    path = Store.budget_path(workspace: workspace)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "capacity" => 100,
        "current" => current,
        "mode" => Atom.to_string(mode_for_current(current)),
        "refill_rate" => 10,
        "last_refilled_at" =>
          DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.to_iso8601(),
        "spent_today" => 0
      })
    )
  end

  defp mode_for_current(0), do: :sleep
  defp mode_for_current(current) when current < 20, do: :low
  defp mode_for_current(current) when current < 80, do: :normal
  defp mode_for_current(_current), do: :deep

  defp wait_until(fun, attempts \\ 40)
  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      wait_until(fun, attempts - 1)
    end
  end
end
