defmodule Nex.Agent.SubagentProfileTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Config, Session, SessionManager, Subagent}
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Subagent.Profile

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-subagent-profile-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(workspace, "memory"))
    previous_workspace = Application.get_env(:nex_agent, :workspace_path)
    Application.put_env(:nex_agent, :workspace_path, workspace)

    start_named_once({Task.Supervisor, name: Nex.Agent.TaskSupervisor}, Nex.Agent.TaskSupervisor)
    start_named_once({Bus, name: Bus}, Bus)
    start_named_once({SessionManager, name: SessionManager}, SessionManager)
    start_named_once({Subagent, name: Subagent}, Subagent)

    on_exit(fn ->
      restore_env(:workspace_path, previous_workspace)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "subagent profile controls prompt model provider options context and tool surface", %{
    workspace: workspace
  } do
    parent = self()
    parent_key = "feishu:chat-1"
    Bus.subscribe(:subagent)
    Bus.subscribe(:inbound)

    parent_session =
      parent_key
      |> Session.new()
      |> Session.add_message("user", "The failing file is lib/example.ex.")
      |> Session.add_message("assistant", "I saw a failing pattern around parse_input/1.")

    SessionManager.save_sync(parent_session, workspace: workspace)

    profile = %Profile{
      name: "reviewer",
      description: "Review risky code.",
      prompt: "Review prompt: find correctness bugs first.",
      model_key: "review-model",
      provider_options: [top_p: 0.4],
      tools_filter: :follow_up,
      tool_allowlist: ["read"],
      context_mode: :parent_recent,
      return_mode: :silent,
      source: :test
    }

    snapshot = snapshot(workspace, %{"reviewer" => profile})

    llm_stream_client = fn messages, opts, callback ->
      send(parent, {:llm_call, messages, opts})
      callback.({:delta, "review done"})
      callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
      :ok
    end

    assert {:ok, task_id} =
             Subagent.spawn_task("Check the parser change.",
               label: "parser-review",
               profile: "reviewer",
               context: "Candidate diff touches parse_input/1.",
               session_key: parent_key,
               workspace: workspace,
               runtime_snapshot: snapshot,
               provider: :anthropic,
               model: "parent-model",
               provider_options: [parent_only: true],
               llm_stream_client: llm_stream_client
             )

    assert_receive {:llm_call, messages, opts}, 2_000

    assert opts[:provider] == :openai
    assert opts[:model] == "review-model-id"
    assert opts[:api_key] == "sk-review"
    assert opts[:base_url] == "https://review.example.com/v1"
    assert opts[:provider_options][:temperature] == 0.1
    assert opts[:provider_options][:top_p] == 0.4
    refute Keyword.has_key?(opts[:provider_options], :parent_only)
    assert opts[:tools_filter] == :follow_up
    assert opts[:tool_allowlist] == ["read"]

    prompt_text =
      messages
      |> Enum.map_join("\n", fn message -> to_string(Map.get(message, "content", "")) end)

    assert prompt_text =~ "Review prompt: find correctness bugs first."
    assert prompt_text =~ "Subagent identity:"
    assert prompt_text =~ "Task ID: #{task_id}"
    assert prompt_text =~ "Profile: reviewer"
    assert prompt_text =~ "Label: parser-review"
    assert prompt_text =~ "Child session: subagent:#{task_id}"
    assert prompt_text =~ "task-scoped background child run"
    assert prompt_text =~ "`run.owner.current` tracks active owner runs only"
    assert prompt_text =~ "Candidate diff touches parse_input/1."
    assert prompt_text =~ "The failing file is lib/example.ex."
    assert prompt_text =~ "Task:\nCheck the parser change."

    assert_eventually(fn ->
      case Subagent.status(task_id) do
        %{status: :completed, result: "review done", profile: "reviewer"} -> true
        _ -> false
      end
    end)

    refute_receive {:bus_message, :subagent, _message}, 100
    refute_receive {:bus_message, :inbound, _message}, 100
  end

  test "inbound completion envelope names child lifecycle and owner gauge boundary", %{
    workspace: workspace
  } do
    Bus.subscribe(:inbound)

    llm_stream_client = fn _messages, _opts, callback ->
      callback.({:delta, "child result"})
      callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
      :ok
    end

    assert {:ok, task_id} =
             Subagent.spawn_task("Smoke test.",
               label: "smoke",
               workspace: workspace,
               llm_stream_client: llm_stream_client
             )

    assert_receive {:bus_message, :inbound, envelope}, 2_000

    assert envelope.text =~ "Subagent task finished"
    assert envelope.text =~ "Task ID: #{task_id}"
    assert envelope.text =~ "Profile: general"
    assert envelope.text =~ "Label: smoke"
    assert envelope.text =~ "Child session: subagent:#{task_id}"
    assert envelope.text =~ "`run.owner.current`, which only lists active owner runs"
    assert envelope.text =~ "Result:\nchild result"
  end

  test "profile config keeps provider options bounded and rejects base surface" do
    assert {:ok, profile} =
             Profile.from_map("custom", %{
               "description" => "Custom bounded profile.",
               "model_role" => "critic",
               "tools_filter" => "base",
               "provider_options" => %{
                 "top_p" => 0.3,
                 "totally_custom_option" => "ignored"
               }
             })

    assert profile.model_role == "critic"
    assert profile.tools_filter == :subagent
    assert profile.provider_options == [top_p: 0.3]
  end

  defp snapshot(workspace, profiles) do
    config =
      Config.from_map(%{
        "max_iterations" => 40,
        "workspace" => workspace,
        "channel" => %{},
        "gateway" => %{"port" => 18_790},
        "provider" => %{
          "providers" => %{
            "review-provider" => %{
              "type" => "openai-compatible",
              "api_key" => "sk-review",
              "base_url" => "https://review.example.com/v1"
            }
          }
        },
        "model" => %{
          "default_model" => "review-model",
          "cheap_model" => "review-model",
          "advisor_model" => "review-model",
          "models" => %{
            "review-model" => %{
              "provider" => "review-provider",
              "id" => "review-model-id",
              "temperature" => 0.1
            }
          }
        },
        "tools" => %{}
      })

    %Snapshot{
      version: 1,
      config: config,
      workspace: workspace,
      channels: %{},
      commands: %{definitions: [], hash: "test"},
      prompt: %{system_prompt: "", diagnostics: [], hash: "test"},
      tools: %{
        definitions_all: [],
        definitions_follow_up: [],
        definitions_subagent: [],
        definitions_cron: [],
        hash: "test"
      },
      subagents: %{profiles: profiles, definitions: [], hash: "test"},
      skills: %{always_instructions: "", hash: "test"},
      changed_paths: []
    }
  end

  defp start_named_once(child_spec, name) do
    if Process.whereis(name) == nil do
      start_supervised!(child_spec)
    end
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp restore_env(key, nil), do: Application.delete_env(:nex_agent, key)
  defp restore_env(key, value), do: Application.put_env(:nex_agent, key, value)
end
