defmodule Nex.Agent.Tool.AskAdvisorTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Config, Session}
  alias Nex.Agent.ControlPlane.Query
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Subagent.Profile
  alias Nex.Agent.Tool.AskAdvisor

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-ask-advisor-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "sessions"))

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "context modes inherit full recent or no parent session context", %{workspace: workspace} do
    parent = self()
    parent_key = "feishu:chat-1"

    parent_key
    |> Session.new()
    |> Session.add_message("user", "old architectural fact")
    |> Session.add_message("assistant", "old assistant analysis")
    |> Session.add_message("user", "recent failing symptom")
    |> Session.save(workspace: workspace)

    ctx = advisor_ctx(workspace, parent_key, stream_client(parent, "advice"))

    assert {:ok, "advice"} =
             AskAdvisor.execute(
               %{
                 "question" => "Should we continue?",
                 "context_mode" => "full",
                 "context" => "manual caller note"
               },
               ctx
             )

    assert_receive {:advisor_call, full_messages, full_opts}
    full_prompt = prompt_text(full_messages)

    assert full_opts[:model] == "advisor-model-id"
    assert full_opts[:provider] == :openai_compatible
    assert full_opts[:api_key] == "sk-advisor"
    assert full_opts[:base_url] == "https://advisor.example.com/v1"
    assert full_opts[:provider_options][:temperature] == 0.2
    assert full_opts[:tools_filter] == :follow_up
    assert full_opts[:tool_allowlist] == []
    assert full_prompt =~ "Question:\nShould we continue?"
    assert full_prompt =~ "Advisor context from parent session (mode=full"
    assert full_prompt =~ "old architectural fact"
    assert full_prompt =~ "recent failing symptom"
    assert full_prompt =~ "Caller-provided advisor context:\nmanual caller note"

    assert {:ok, "advice"} =
             AskAdvisor.execute(
               %{
                 "question" => "What changed?",
                 "context_mode" => "recent",
                 "context_window" => 1
               },
               ctx
             )

    assert_receive {:advisor_call, recent_messages, _recent_opts}
    recent_prompt = prompt_text(recent_messages)

    assert recent_prompt =~ "Advisor context from parent session (mode=recent"
    assert recent_prompt =~ "recent failing symptom"
    refute recent_prompt =~ "old architectural fact"

    assert {:ok, "advice"} =
             AskAdvisor.execute(
               %{
                 "question" => "No inherited context?",
                 "context_mode" => "none",
                 "context" => "manual only"
               },
               ctx
             )

    assert_receive {:advisor_call, none_messages, _none_opts}
    none_prompt = prompt_text(none_messages)

    refute none_prompt =~ "Advisor context from parent session"
    assert none_prompt =~ "Caller-provided advisor context:\nmanual only"

    observations = Query.query(%{"tag" => "advisor.call.finished"}, workspace: workspace)
    assert Enum.any?(observations, &(&1["attrs"]["profile"] == "advisor"))
  end

  test "model_key override uses configured model runtime", %{workspace: workspace} do
    parent = self()

    ctx =
      advisor_ctx(workspace, "feishu:model-override", stream_client(parent, "override advice"))

    assert {:ok, "override advice"} =
             AskAdvisor.execute(
               %{
                 "question" => "Use another model?",
                 "context_mode" => "none",
                 "model_key" => "critic-model"
               },
               ctx
             )

    assert_receive {:advisor_call, _messages, opts}

    assert opts[:provider] == :anthropic
    assert opts[:model] == "critic-model-id"
    assert opts[:api_key] == "sk-critic"
    assert opts[:base_url] == "https://critic.example.com/v1"
    assert opts[:provider_options][:top_p] == 0.4
  end

  test "unknown profile returns a stable error without running advisor", %{workspace: workspace} do
    parent = self()
    ctx = advisor_ctx(workspace, "feishu:unknown-profile", stream_client(parent, "unused"))

    assert {:error, "unknown advisor profile: missing"} =
             AskAdvisor.execute(
               %{"question" => "Use which profile?", "profile" => "missing"},
               ctx
             )

    refute_receive {:advisor_call, _messages, _opts}, 50
  end

  defp advisor_ctx(workspace, session_key, stream_client) do
    config = config(workspace)

    snapshot = %Snapshot{
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
      subagents: %{profiles: profiles(), definitions: [], hash: "test"},
      skills: %{cards: [], catalog_prompt: "", diagnostics: [], hash: "test"},
      changed_paths: []
    }

    %{
      workspace: workspace,
      cwd: workspace,
      session_key: session_key,
      run_id: "owner-run-1",
      runtime_snapshot: snapshot,
      config: config,
      llm_stream_client: stream_client
    }
  end

  defp profiles do
    Profile.builtin_profiles()
  end

  defp config(workspace) do
    Config.from_map(%{
      "workspace" => workspace,
      "channel" => %{},
      "gateway" => %{"port" => 18_790},
      "provider" => %{
        "providers" => %{
          "advisor-provider" => %{
            "type" => "openai-compatible",
            "api_key" => "sk-advisor",
            "base_url" => "https://advisor.example.com/v1"
          },
          "critic-provider" => %{
            "type" => "anthropic",
            "api_key" => "sk-critic",
            "base_url" => "https://critic.example.com/v1"
          }
        }
      },
      "model" => %{
        "default_model" => "advisor-model",
        "cheap_model" => "advisor-model",
        "advisor_model" => "advisor-model",
        "models" => %{
          "advisor-model" => %{
            "provider" => "advisor-provider",
            "id" => "advisor-model-id",
            "temperature" => 0.2
          },
          "critic-model" => %{
            "provider" => "critic-provider",
            "id" => "critic-model-id",
            "top_p" => 0.4
          }
        }
      },
      "tools" => %{}
    })
  end

  defp stream_client(parent, response_text) do
    fn messages, opts, callback ->
      send(parent, {:advisor_call, messages, opts})
      callback.({:delta, response_text})
      callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
      :ok
    end
  end

  defp prompt_text(messages) do
    messages
    |> Enum.map_join("\n", fn message -> to_string(Map.get(message, "content", "")) end)
  end
end
