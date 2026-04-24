defmodule Nex.SkillRuntimeTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{RequestTrace, Runner, Session}
  alias Nex.Agent.Tool.Registry
  alias Nex.SkillRuntime

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-skill-runtime-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(workspace, "skills"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")
    File.write!(Path.join(workspace, "memory/HISTORY.md"), "# History\n")

    if Process.whereis(Nex.Agent.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: Nex.Agent.TaskSupervisor})
    end

    if Process.whereis(Registry) == nil do
      start_supervised!({Registry, name: Registry})
    end

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "search indexes local package skills and infers playbook mode", %{workspace: workspace} do
    package_dir = Path.join(workspace, "skills/rt__local_widget_playbook")
    File.mkdir_p!(Path.join(package_dir, "scripts"))

    File.write!(
      Path.join(package_dir, "SKILL.md"),
      """
      ---
      name: local-widget-playbook
      description: Diagnose widget issues from logs
      entry_script: scripts/run.sh
      ---

      Inspect widget logs and produce a diagnosis.
      """
    )

    File.write!(Path.join(package_dir, "scripts/run.sh"), "#!/bin/sh\necho ok\n")

    assert {:ok, hits} =
             SkillRuntime.search("widget logs diagnosis",
               workspace: workspace,
               project_root: workspace,
               skill_runtime: %{"enabled" => true}
             )

    assert [%{type: :local, package: package} | _] = hits
    assert package.execution_mode == "playbook"
    assert package.tool_name == "skill_run__local_widget_playbook"
  end

  test "trusted github catalog sync and import download a package directory", %{
    workspace: workspace
  } do
    skill_md = """
    ---
    name: remote-widget-playbook
    description: Remote widget diagnosis package
    entry_script: scripts/run.sh
    execution_mode: playbook
    ---

    Use this package when the widget breaks in production.
    """

    script = "#!/bin/sh\necho remote:$1\n"

    entry = %{
      "source_id" => "remote-widget-playbook",
      "repo" => "acme/skills",
      "commit_sha" => "abc123",
      "path" => "packages/remote-widget-playbook",
      "name" => "remote-widget-playbook",
      "description" => "Remote widget diagnosis package",
      "execution_mode" => "playbook",
      "entry_script" => "scripts/run.sh",
      "dependencies" => [],
      "required_keys" => [],
      "allowed_tools" => [],
      "tags" => ["widget", "ops"],
      "host_compat" => ["nex_agent"],
      "risk_level" => "low",
      "file_manifest" => %{
        "SKILL.md" => sha256(skill_md),
        "scripts/run.sh" => sha256(script)
      },
      "package_checksum" => sha256(skill_md <> script)
    }

    http_get = fake_http_get(skill_md, script, entry)

    assert {:ok, hits} =
             SkillRuntime.search("remote widget diagnosis",
               workspace: workspace,
               project_root: workspace,
               http_get: http_get,
               skill_runtime: %{
                 "enabled" => true,
                 "github_indexes" => [
                   %{"repo" => "org/index", "ref" => "main", "path" => "index.json"}
                 ]
               }
             )

    assert Enum.any?(
             hits,
             &(&1.type == :remote and &1.entry.source_id == "remote-widget-playbook")
           )

    assert {:ok, package} =
             SkillRuntime.import("remote-widget-playbook",
               workspace: workspace,
               project_root: workspace,
               http_get: http_get,
               skill_runtime: %{
                 "enabled" => true,
                 "github_indexes" => [
                   %{"repo" => "org/index", "ref" => "main", "path" => "index.json"}
                 ]
               }
             )

    assert package.execution_mode == "playbook"
    assert File.exists?(Path.join(package.root_path, "source.json"))
    assert File.exists?(Path.join(package.root_path, ".skill_id"))
    assert File.exists?(Path.join(package.root_path, "scripts/run.sh"))
  end

  test "runner exposes and executes ephemeral playbook tools", %{workspace: workspace} do
    package_dir = Path.join(workspace, "skills/rt__widget_ops")
    File.mkdir_p!(Path.join(package_dir, "scripts"))

    File.write!(
      Path.join(package_dir, "SKILL.md"),
      """
      ---
      name: widget-ops
      description: Handle widget incidents
      execution_mode: playbook
      entry_script: scripts/run.sh
      parameters:
        type: object
        properties:
          task:
            type: string
      ---

      Use this skill when the widget is down and you need the incident playbook.
      """
    )

    File.write!(Path.join(package_dir, "scripts/run.sh"), "#!/bin/sh\necho playbook:$1\n")

    parent = self()
    Process.put(:skill_runtime_llm_calls, 0)

    llm_client = fn _messages, opts ->
      send(parent, {:tools, Keyword.get(opts, :tools, [])})

      case Process.get(:skill_runtime_llm_calls, 0) do
        0 ->
          Process.put(:skill_runtime_llm_calls, 1)

          {:ok,
           %{
             content: "",
             finish_reason: nil,
             tool_calls: [
               %{
                 id: "skill_run",
                 function: %{
                   name: "skill_run__widget_ops",
                   arguments: %{"task" => "restore service"}
                 }
               }
             ]
           }}

        _ ->
          {:ok, %{content: "done", finish_reason: nil, tool_calls: []}}
      end
    end

    assert {:ok, "done", session} =
             Runner.run(Session.new("skill-runtime"), "run the widget incident playbook",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               cwd: workspace,
               skill_runtime: %{"enabled" => true},
               skip_consolidation: true
             )

    assert_receive {:tools, tools}
    assert Enum.any?(tools, &(&1["name"] == "skill_run__widget_ops"))

    tool_message =
      Enum.find(session.messages, fn message ->
        message["role"] == "tool" and message["name"] == "skill_run__widget_ops"
      end)

    assert tool_message["content"] =~ "playbook:{\"task\":\"restore service\"}"

    runs_dir = Path.join(workspace, "skill_runtime/runs")
    assert [_ | _] = Path.wildcard(Path.join(runs_dir, "*.jsonl"))
  end

  test "draft runtime packages are not selected or exposed as ephemeral tools", %{
    workspace: workspace
  } do
    package_dir = Path.join(workspace, "skills/rt__draft_widget_ops")
    File.mkdir_p!(Path.join(package_dir, "scripts"))

    File.write!(
      Path.join(package_dir, "SKILL.md"),
      """
      ---
      name: draft-widget-ops
      description: [Draft] Handle widget incidents
      execution_mode: playbook
      entry_script: scripts/run.sh
      ---

      <!-- status: draft, source: evolution -->

      Use this skill when the widget is down.
      """
    )

    File.write!(Path.join(package_dir, "scripts/run.sh"), "#!/bin/sh\necho should-not-run\n")

    assert {:ok, hits} =
             SkillRuntime.search("widget incidents",
               workspace: workspace,
               project_root: workspace,
               skill_runtime: %{"enabled" => true}
             )

    refute Enum.any?(hits, fn
             %{type: :local, package: package} -> package.name == "draft-widget-ops"
             _ -> false
           end)

    assert {:ok, prepared_run} =
             SkillRuntime.prepare_run("run the widget incident playbook",
               workspace: workspace,
               project_root: workspace,
               skill_runtime: %{"enabled" => true}
             )

    assert prepared_run.selected_packages == []
    assert prepared_run.ephemeral_tools == []
  end

  test "prepare_run prefers poster skill over URL noise for Chinese poster prompts", %{
    workspace: workspace
  } do
    poster_dir = Path.join(workspace, "skills/rt__article_poster")
    File.mkdir_p!(poster_dir)

    File.write!(
      Path.join(poster_dir, "SKILL.md"),
      """
      ---
      name: article-poster
      description: Trigger when user says "文章海报", "信息图", or "生成海报".
      ---

      Use this skill to turn an article or URL into a poster image.
      """
    )

    github_dir = Path.join(workspace, "skills/rt__github_deep_research")
    File.mkdir_p!(github_dir)

    File.write!(
      Path.join(github_dir, "SKILL.md"),
      """
      ---
      name: github-deep-research
      description: Research GitHub repositories and pull requests.
      ---

      This skill explains how to inspect https://github.com links, compare commits,
      review pull requests, and fetch screenshots from repository pages.
      """
    )

    assert {:ok, prepared_run} =
             SkillRuntime.prepare_run("生成海报 https://github.com/HKUDS/nanobot 16:9 三列",
               workspace: workspace,
               project_root: workspace,
               skill_runtime: %{"enabled" => true}
             )

    assert [first | _] = prepared_run.selected_packages
    assert first.name == "article-poster"
  end

  test "runner adds authoritative guard when a knowledge skill is selected", %{
    workspace: workspace
  } do
    package_dir = Path.join(workspace, "skills/rt__article_poster")
    File.mkdir_p!(package_dir)

    File.write!(
      Path.join(package_dir, "SKILL.md"),
      """
      ---
      name: article-poster
      description: Trigger when user says "生成海报".
      ---

      Render the poster with render.mjs and deliver the PNG artifact.
      """
    )

    parent = self()

    llm_client = fn messages, _opts ->
      send(parent, {:messages, messages})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    assert {:ok, "ok", _session} =
             Runner.run(Session.new("skill-runtime-guard"), "生成海报",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               cwd: workspace,
               skill_runtime: %{"enabled" => true},
               skip_consolidation: true
             )

    assert_receive {:messages, messages}

    assert Enum.any?(messages, fn message ->
             message["role"] == "system" and
               String.contains?(
                 message["content"],
                 "Selected skill packages for this turn are authoritative: article-poster"
               )
           end)
  end

  test "runner skips runtime skill selection entirely when skip_skills is true", %{
    workspace: workspace
  } do
    package_dir = Path.join(workspace, "skills/rt__legacy_summary_helper")
    File.mkdir_p!(package_dir)

    File.write!(
      Path.join(package_dir, "SKILL.md"),
      """
      ---
      name: legacy-summary-helper
      description: Use when the prompt says "legacy summary" or asks for a scheduled summary.
      ---

      Handle legacy summary prompts.
      """
    )

    assert {:ok, prepared_run} =
             SkillRuntime.prepare_run("legacy summary",
               workspace: workspace,
               cwd: workspace,
               skill_runtime: %{"enabled" => true}
             )

    assert Enum.any?(prepared_run.selected_packages, &(&1.name == "legacy-summary-helper"))

    parent = self()

    llm_client = fn messages, _opts ->
      send(parent, {:messages, messages})
      {:ok, %{content: "ok", finish_reason: nil, tool_calls: []}}
    end

    assert {:ok, "ok", _session} =
             Runner.run(Session.new("skip-runtime-skills"), "legacy summary",
               llm_stream_client: stream_client_from_response(llm_client),
               workspace: workspace,
               cwd: workspace,
               skill_runtime: %{"enabled" => true},
               request_trace: %{"enabled" => true},
               skip_skills: true,
               skip_consolidation: true
             )

    assert_receive {:messages, messages}

    refute Enum.any?(messages, fn message ->
             message["role"] == "system" and
               String.contains?(message["content"], "Selected skill packages for this turn")
           end)

    [trace_path] =
      RequestTrace.list_paths(workspace: workspace, request_trace: %{"enabled" => true})

    started =
      trace_path
      |> RequestTrace.read_trace(workspace: workspace, request_trace: %{"enabled" => true})
      |> Enum.find(&(&1["type"] == "request_started"))

    assert started["selected_package_count"] == 0
    assert started["selected_package_names"] == []
  end

  defp fake_http_get(skill_md, script, entry) do
    fn url, _opts ->
      body =
        cond do
          String.contains?(url, "/repos/org/index/contents/index.json?ref=main") ->
            Jason.encode!(%{"content" => Base.encode64(Jason.encode!(%{"skills" => [entry]}))})

          String.contains?(
            url,
            "/repos/acme/skills/contents/packages/remote-widget-playbook?ref=abc123"
          ) ->
            Jason.encode!([
              %{
                "type" => "file",
                "name" => "SKILL.md",
                "path" => "packages/remote-widget-playbook/SKILL.md",
                "download_url" => "https://download.example/skill_md"
              },
              %{
                "type" => "dir",
                "name" => "scripts",
                "path" => "packages/remote-widget-playbook/scripts"
              }
            ])

          String.contains?(
            url,
            "/repos/acme/skills/contents/packages/remote-widget-playbook/scripts?ref=abc123"
          ) ->
            Jason.encode!([
              %{
                "type" => "file",
                "name" => "run.sh",
                "path" => "packages/remote-widget-playbook/scripts/run.sh",
                "download_url" => "https://download.example/run_sh"
              }
            ])

          url == "https://download.example/skill_md" ->
            skill_md

          url == "https://download.example/run_sh" ->
            script

          true ->
            ""
        end

      {:ok, %{status: 200, body: body}}
    end
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

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

    case render_mock_content(content) do
      "" -> :ok
      text -> callback.({:delta, text})
    end

    tool_calls = Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || []

    if tool_calls != [] do
      callback.({:tool_calls, tool_calls})
    end

    callback.({:done, %{finish_reason: nil, usage: nil, model: nil}})
  end

  defp render_mock_content(nil), do: ""
  defp render_mock_content(text) when is_binary(text), do: text
  defp render_mock_content(text), do: inspect(text, printable_limit: 500, limit: 50)
end
