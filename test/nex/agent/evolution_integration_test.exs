defmodule Nex.Agent.EvolutionIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Evolution, Runner, Session, Skills}
  alias Nex.Agent.ControlPlane.{Log, Query, Store}
  alias Nex.Agent.Tool.{EvolutionCandidate, Reflect}
  require Log

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-evo-integ-#{System.unique_integer([:positive])}")

    for dir <- ~w(memory skills sessions) do
      File.mkdir_p!(Path.join(workspace, dir))
    end

    File.write!(Path.join(workspace, "SOUL.md"), "# Soul\n\n- Be helpful\n- Be concise\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n- likes structured output\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")
    File.write!(Path.join(workspace, "memory/HISTORY.md"), "")

    Application.put_env(:nex_agent, :workspace_path, workspace)

    for {mod, name} <- [
          {Task.Supervisor, Nex.Agent.TaskSupervisor},
          {Bus, Bus},
          {Nex.Agent.Tool.Registry, Nex.Agent.Tool.Registry}
        ] do
      if Process.whereis(name) == nil do
        start_supervised!({mod, name: name})
      end
    end

    if Process.whereis(Skills) == nil do
      start_supervised!({Skills, []})
    end

    Skills.load()

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      Process.sleep(100)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "runner signals become ControlPlane evidence and evolution emits candidate observations", %{
    workspace: workspace
  } do
    write_budget(workspace, 60)

    llm_client = fn _messages, _opts ->
      {:ok, %{content: "好的", finish_reason: nil, tool_calls: []}}
    end

    correction_prompts = [
      "不对，应该用 JSON 格式返回",
      "改成 snake_case 命名",
      "actually use PostgreSQL not MySQL"
    ]

    Enum.reduce(correction_prompts, Session.new("evo-integ"), fn prompt, session ->
      {:ok, _result, updated} =
        Runner.run(session, prompt,
          llm_stream_client: stream_client_from_response(llm_client),
          workspace: workspace,
          skip_consolidation: true
        )

      updated
    end)

    signals = Evolution.recent_signals(workspace: workspace)
    assert length(signals) >= 2

    assert Enum.any?(signals, fn signal ->
             signal["attrs_summary"]["source"] == "runner"
           end)

    assert {:ok, _} =
             Log.error(
               "runner.tool.call.failed",
               %{"tool_name" => "bash", "reason_type" => "exit_status"},
               workspace: workspace,
               run_id: "run-evo"
             )

    assert {:ok, _} =
             Log.error(
               "runner.tool.call.failed",
               %{"tool_name" => "bash", "reason_type" => "exit_status"},
               workspace: workspace,
               run_id: "run-evo"
             )

    assert {:ok, _} =
             Log.warning(
               "http.request.failed",
               %{"reason_type" => "timeout"},
               workspace: workspace,
               run_id: "run-evo"
             )

    soul_before = File.read!(Path.join(workspace, "SOUL.md"))
    memory_before = File.read!(Path.join(workspace, "memory/MEMORY.md"))
    skill_dirs_before = Path.wildcard(Path.join(workspace, "skills/*"))
    parent = self()

    evolution_llm = fn messages, _opts ->
      user_msg = Enum.find(messages, &(&1["role"] == "user"))
      prompt = user_msg["content"]
      send(parent, {:prompt, prompt})

      evidence_ids =
        Query.query(%{"limit" => 50}, workspace: workspace)
        |> Enum.map(& &1["id"])
        |> Enum.take(3)

      {:ok,
       %{
         "observations" => "Repeated tool failures plus correction signals suggest targeted code follow-up.",
         "candidates" => [
           %{
             "kind" => "code_hint",
             "summary" => "Harden repeated tool failure handling",
             "rationale" => "The same tool failure recurred and user correction signals followed.",
             "evidence_ids" => evidence_ids,
             "risk" => "medium"
           },
           %{
             "kind" => "memory_candidate",
             "summary" => "Review whether JSON output preference belongs in durable memory",
             "rationale" => "User corrections repeatedly mentioned JSON output.",
             "evidence_ids" => Enum.map(signals, & &1["id"]) |> Enum.take(2),
             "risk" => "low"
           }
         ]
       }}
    end

    {:ok, result} =
      Evolution.run_evolution_cycle(
        workspace: workspace,
        trigger: :manual,
        llm_call_fun: evolution_llm
      )

    assert result.status == :completed
    assert result.budget_mode == :normal
    assert result.candidate_count == 2
    assert Enum.all?(result.candidates, &(&1["requires_owner_approval"] == true))

    assert_receive {:prompt, prompt}, 500
    assert prompt =~ "\"trigger\": \"manual\""
    assert prompt =~ "\"budget\""
    assert prompt =~ "\"patterns\""
    assert prompt =~ "\"candidate_history\""

    assert File.read!(Path.join(workspace, "SOUL.md")) == soul_before
    assert File.read!(Path.join(workspace, "memory/MEMORY.md")) == memory_before
    assert Path.wildcard(Path.join(workspace, "skills/*")) == skill_dirs_before

    events = Evolution.recent_events(workspace: workspace)
    tags = Enum.map(events, & &1["tag"])
    assert "evolution.cycle.started" in tags
    assert "evolution.cycle.completed" in tags
    assert "evolution.candidate.proposed" in tags

    candidate_observations =
      Query.query(%{"tag" => "evolution.candidate.proposed", "limit" => 10}, workspace: workspace)

    assert length(candidate_observations) == 2
    assert Enum.all?(candidate_observations, fn observation ->
             attrs = observation["attrs"]
             is_list(attrs["evidence_ids"]) and attrs["requires_owner_approval"] == true
           end)
  end

  test "reflect tool reports recent signals and candidate history from ControlPlane", %{
    workspace: workspace
  } do
    write_budget(workspace, 10)

    Evolution.record_signal(%{source: "runner", signal: "User corrected format"}, workspace: workspace)

    assert {:ok, _} =
             Log.error(
               "runner.tool.call.failed",
               %{"tool_name" => "bash", "reason_type" => "exit_status"},
               workspace: workspace
             )

    assert {:ok, _} =
             Log.error(
               "runner.tool.call.failed",
               %{"tool_name" => "bash", "reason_type" => "exit_status"},
               workspace: workspace
             )

    assert {:ok, result} = Evolution.run_evolution_cycle(workspace: workspace)
    assert result.candidate_count == 1

    {:ok, status} = Reflect.execute(%{"action" => "evolution_status"}, %{workspace: workspace})
    assert status =~ "Evolution Status"
    assert status =~ "evolution.candidate.proposed"
    assert status =~ "recent signal observation"

    {:ok, history} = Reflect.execute(%{"action" => "evolution_history"}, %{workspace: workspace})
    assert history =~ "evolution.candidate.proposed"
    assert history =~ "Cycle Completed"
  end

  test "approved non-code candidates realize and apply through deterministic tool lanes", %{
    workspace: workspace
  } do
    assert {:ok, _} =
             Log.info(
               "evolution.candidate.proposed",
               %{
                 "id" => "cand_memory_apply",
                 "kind" => "memory_candidate",
                 "summary" => "Remember JSON output preference",
                 "rationale" => "User repeatedly requested JSON output.",
                 "evidence_ids" => ["obs_1"],
                 "risk" => "low",
                 "requires_owner_approval" => true,
                 "created_at" => Store.timestamp()
               },
               workspace: workspace
             )

    assert {:ok, approved} =
             EvolutionCandidate.execute(
               %{"action" => "approve", "candidate_id" => "cand_memory_apply"},
               %{workspace: workspace}
             )

    assert approved["apply"]["status"] == "applied"
    assert File.read!(Path.join(workspace, "memory/MEMORY.md")) =~ "Remember JSON output preference"

    assert {:ok, candidate} = Evolution.candidate("cand_memory_apply", workspace: workspace)
    assert candidate["status"] == "applied"

    tags =
      Query.query(%{"tag_prefix" => "evolution.candidate.", "limit" => 20}, workspace: workspace)
      |> Enum.map(& &1["tag"])

    assert "evolution.candidate.approved" in tags
    assert "evolution.candidate.realization.generated" in tags
    assert "evolution.candidate.apply.started" in tags
    assert "evolution.candidate.apply.completed" in tags
  end

  defp write_budget(workspace, current) do
    path = Store.budget_path(workspace: workspace)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "capacity" => 100,
        "current" => current,
        "mode" => mode_for_current(current),
        "refill_rate" => 10,
        "last_refilled_at" =>
          DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.to_iso8601(),
        "spent_today" => 0
      })
    )
  end

  defp mode_for_current(0), do: "sleep"
  defp mode_for_current(current) when current < 20, do: "low"
  defp mode_for_current(current) when current < 80, do: "normal"
  defp mode_for_current(_current), do: "deep"

  defp stream_client_from_response(fun) when is_function(fun, 2) do
    fn messages, opts, callback ->
      case fun.(messages, opts) do
        {:ok, response} when is_map(response) ->
          emit_mock_stream_response(callback, response)
          :ok

        {:error, reason} ->
          {:error, reason}

        response when is_map(response) ->
          emit_mock_stream_response(callback, response)
          :ok

        other ->
          other
      end
    end
  end

  defp emit_mock_stream_response(callback, response) do
    content = Map.get(response, :content) || Map.get(response, "content") || ""

    if content != "" do
      callback.({:delta, content})
    end
  end
end
