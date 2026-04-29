defmodule Nex.Agent.Workbench.ServerTest do
  use ExUnit.Case, async: false

  require Nex.Agent.ControlPlane.Log

  alias Nex.Agent.Config
  alias Nex.Agent.ControlPlane.Query
  alias Nex.Agent.ControlPlane.Store, as: ControlPlaneStore
  alias Nex.Agent.Evolution
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.{RunControl, Runtime, Session, SessionManager}
  alias Nex.Agent.Workbench.{Server, Store}

  setup do
    if Process.whereis(SessionManager) == nil do
      start_supervised!({SessionManager, name: SessionManager})
    end

    if Process.whereis(RunControl) == nil do
      start_supervised!({RunControl, name: RunControl})
    end

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-workbench-server-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(workspace) end)

    :inets.start()

    {:ok, workspace: workspace}
  end

  test "disabled runtime does not bind a listener", %{workspace: workspace} do
    pid =
      start_server!(%Snapshot{
        workspace: workspace,
        workbench: %{
          runtime: %{"enabled" => false, "host" => "127.0.0.1", "port" => 0},
          apps: [],
          diagnostics: [],
          hash: ""
        }
      })

    assert %{enabled: false, running: false, port: nil} = Server.status(pid)
  end

  test "serves workbench apps and permissions from runtime workspace and port", %{
    workspace: workspace
  } do
    assert {:ok, _} =
             Store.save(
               %{
                 "id" => "notes",
                 "title" => "Notes",
                 "entry" => "src/App.tsx",
                 "permissions" => ["notes:read", "notes:write"],
                 "chrome" => %{"topbar" => "hidden"}
               },
               workspace: workspace
             )

    snapshot = snapshot(workspace)
    pid = start_server!(snapshot)
    %{running: true, host: "127.0.0.1", port: port} = Server.status(pid)

    assert port > 0

    assert {200,
            %{
              "apps" => [%{"id" => "notes", "chrome" => %{"topbar" => "hidden"}}],
              "diagnostics" => []
            }} =
             get_json(port, "/api/workbench/apps")

    assert {200,
            %{
              "app" => %{
                "id" => "notes",
                "title" => "Notes",
                "chrome" => %{"topbar" => "hidden"}
              }
            }} =
             get_json(port, "/api/workbench/apps/notes")

    assert {200, %{"permissions" => %{"granted_permissions" => []}}} =
             get_json(port, "/api/workbench/permissions/notes")

    assert {200, %{"permissions" => %{"granted_permissions" => ["notes:read"]}}} =
             post_json(port, "/api/workbench/permissions/notes/grant", %{
               "permission" => "notes:read"
             })

    assert {200, %{"permissions" => %{"granted_permissions" => []}}} =
             post_json(port, "/api/workbench/permissions/notes/revoke", %{
               "permission" => "notes:read"
             })

    assert {200, %{"recent" => recent, "budget" => %{}, "gauges" => %{}}} =
             get_json(port, "/api/observe/summary")

    assert Enum.any?(recent, &(&1["tag"] == "workbench.permission.granted"))
  end

  test "app catalog endpoint reflects newly written manifests without runtime reload", %{
    workspace: workspace
  } do
    pid = start_server!(snapshot(workspace))
    %{running: true, port: port} = Server.status(pid)

    assert {200, %{"apps" => [], "diagnostics" => []}} =
             get_json(port, "/api/workbench/apps")

    assert {:ok, _} =
             Store.save(
               %{
                 "id" => "fresh-app",
                 "title" => "Fresh",
                 "permissions" => ["permissions:read"]
               },
               workspace: workspace
             )

    assert {200, %{"apps" => [%{"id" => "fresh-app", "entry" => "index.html"}]}} =
             get_json(port, "/api/workbench/apps")
  end

  test "serves filtered observation timeline queries", %{workspace: workspace} do
    {:ok, _} =
      Nex.Agent.ControlPlane.Log.warning(
        "runner.tool.call.failed",
        %{"tool_name" => "read", "summary" => "missing file"},
        workspace: workspace,
        run_id: "run-filtered",
        session_key: "session-filtered",
        channel: "feishu",
        tool_call_id: "tool-call-filtered"
      )

    {:ok, _} =
      Nex.Agent.ControlPlane.Log.info(
        "runner.run.started",
        %{},
        workspace: workspace,
        run_id: "run-other",
        session_key: "session-filtered",
        channel: "discord"
      )

    pid = start_server!(snapshot(workspace))
    %{running: true, port: port} = Server.status(pid)

    assert {200, %{"filters" => filters, "observations" => [observation]}} =
             get_json(
               port,
               "/api/observe/query?tag_prefix=runner.tool.&run_id=run-filtered&session_key=session-filtered&channel=feishu&tool=read&level=warning&limit=20"
             )

    assert filters["tag_prefix"] == "runner.tool."
    assert observation["tag"] == "runner.tool.call.failed"
    assert observation["level"] == "warning"
    assert observation["context"]["tool_call_id"] == "tool-call-filtered"
    assert observation["attrs"]["tool_name"] == "read"
  end

  test "serves shell and sandbox app frame", %{workspace: workspace} do
    assert {:ok, _} =
             Store.save(
               %{
                 "id" => "notes",
                 "title" => "Notes",
                 "permissions" => ["notes:read"]
               },
               workspace: workspace
             )

    app_dir = Path.join([workspace, "workbench", "apps", "notes"])

    File.write!(
      Path.join(app_dir, "index.html"),
      ~s(<!doctype html><html><head><title>Notes</title><link rel="stylesheet" href="style.css"></head><body><h1>Notes App</h1><script src="app.js"></script></body></html>)
    )

    File.write!(Path.join(app_dir, "app.js"), "window.notesLoaded = true;")
    File.write!(Path.join(app_dir, "style.css"), "body { color: #20251f; }")

    pid = start_server!(snapshot(workspace))
    %{running: true, port: port} = Server.status(pid)

    assert {200, shell} = get_raw(port, "/workbench")
    assert shell =~ "Nex Workbench"
    assert shell =~ "Self Evolution"
    assert shell =~ "Sessions"
    assert shell =~ "sandbox = \"allow-scripts\""
    assert shell =~ "id=\"reload-app\""
    assert shell =~ "nex.workbench.shell.view.v1"
    assert shell =~ "restoreInitialView"
    assert shell =~ "app-immersive"
    assert shell =~ "app-topbar-hidden"
    assert shell =~ "app-chrome-hotzone"
    assert shell =~ "appTopbarMode"
    assert shell =~ "id=\"sidebar-edge\""
    assert shell =~ "#app-view .stage-bar"
    assert shell =~ "grid-template-rows: minmax(0, 1fr);"
    assert shell =~ "id=\"toast-region\""
    assert shell =~ "id=\"confirm-modal\""
    assert shell =~ "Discard unsaved configuration changes?"
    assert shell =~ "aria-live=\"polite\""
    assert shell =~ "window.addEventListener(\"message\", handleBridgeMessage)"
    refute shell =~ "window.confirm"
    refute shell =~ "alert(error.message)"
    assert shell =~ "/api/workbench/apps"
    assert shell =~ "/api/workbench/evolution"
    assert shell =~ "/api/workbench/sessions"

    assert {200, frame} = get_raw(port, "/app-frame/notes")
    assert frame =~ "<title>Notes</title>"
    assert frame =~ "Notes App"
    assert frame =~ ~s(<base href="/app-assets/notes/">)
    assert frame =~ "window.Nex"
    assert frame =~ "workbench.bridge.request"

    assert {200, js_headers, js} = get_raw_with_headers(port, "/app-assets/notes/app.js")
    assert header_value(js_headers, "access-control-allow-origin") == "*"
    assert header_value(js_headers, "cross-origin-resource-policy") == "cross-origin"
    assert js =~ "notesLoaded"

    assert {400, %{"error" => "nex.app.json is not served" <> _}} =
             get_json(port, "/app-assets/notes/nex.app.json")

    assert {404, missing} = get_raw(port, "/app-frame/missing")
    assert missing =~ "Missing app"
  end

  test "serves backend bridge route with app-bound permissions", %{workspace: workspace} do
    assert {:ok, _} =
             Store.save(
               %{
                 "id" => "bridge-app",
                 "title" => "Bridge",
                 "permissions" => ["permissions:read", "observe:read"]
               },
               workspace: workspace
             )

    pid = start_server!(snapshot(workspace))
    %{running: true, port: port} = Server.status(pid)

    assert {200, %{"ok" => false, "error" => %{"code" => "permission_denied"}}} =
             post_json(port, "/api/workbench/bridge/bridge-app/call", %{
               "call_id" => "call_denied",
               "method" => "permissions.current",
               "params" => %{},
               "app_id" => "other-app"
             })

    assert {200, %{"permissions" => %{"granted_permissions" => ["permissions:read"]}}} =
             post_json(port, "/api/workbench/permissions/bridge-app/grant", %{
               "permission" => "permissions:read"
             })

    assert {200,
            %{
              "call_id" => "call_permissions",
              "ok" => true,
              "result" => %{
                "app_id" => "bridge-app",
                "granted_permissions" => ["permissions:read"]
              }
            }} =
             post_json(port, "/api/workbench/bridge/bridge-app/call", %{
               "call_id" => "call_permissions",
               "method" => "permissions.current",
               "params" => %{},
               "app_id" => "other-app"
             })

    request = [
      "POST /api/workbench/bridge/bridge-app/call HTTP/1.1\r\n",
      "Host: 127.0.0.1\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: 9\r\n",
      "\r\n",
      "{bad json"
    ]

    assert {400, body} = raw_http(port, request)
    assert body =~ "invalid JSON"
  end

  test "serves session inventory detail stop and model override actions", %{workspace: workspace} do
    session_key = "feishu:chat-session"

    session =
      session_key
      |> Session.new()
      |> Session.add_message("user", "start the long task")
      |> Session.add_message("assistant", "working")

    :ok = Session.save(session, workspace: workspace)
    SessionManager.invalidate(session_key, workspace: workspace)

    assert {:ok, run} =
             RunControl.start_owner(
               workspace,
               session_key,
               channel: "feishu",
               chat_id: "chat-session"
             )

    assert :ok = RunControl.set_phase(run.id, :tool)
    assert :ok = RunControl.append_tool_output(run.id, "read", "reading files")

    pid = start_server!(snapshot(workspace, config: model_config()))
    %{running: true, port: port} = Server.status(pid)

    assert {200,
            %{
              "summary" => %{"running" => 1, "total" => 1},
              "sessions" => [
                %{
                  "key" => ^session_key,
                  "status" => "running",
                  "run" => %{"run_id" => run_id, "current_tool" => "read"},
                  "model" => %{"current_key" => "gpt-5.4", "source" => "default"}
                }
              ]
            }} = get_json(port, "/api/workbench/sessions")

    assert run_id == run.id

    assert {200,
            %{
              "session" => %{
                "key" => ^session_key,
                "available_models" => [%{"key" => "gpt-5.4"}, %{"key" => "hy3-preview"}],
                "messages" => [_ | _],
                "recent_observations" => [_ | _]
              }
            }} = get_json(port, "/api/workbench/sessions/#{URI.encode(session_key)}")

    assert {200, %{"session" => %{"model" => %{"current_key" => "hy3-preview"}}}} =
             post_json(port, "/api/workbench/sessions/#{URI.encode(session_key)}/model", %{
               "model" => "2"
             })

    assert Session.model_override(Session.load(session_key, workspace: workspace)) ==
             "hy3-preview"

    assert {200,
            %{
              "result" => %{
                "cancelled?" => true,
                "run_id" => ^run_id,
                "dropped_queued" => 0
              }
            }} =
             post_json(port, "/api/workbench/sessions/#{URI.encode(session_key)}/stop", %{
               "reason" => "test_stop"
             })

    assert {:error, :idle} = RunControl.owner_snapshot(workspace, session_key)

    assert {200, %{"session" => %{"model" => %{"current_key" => "gpt-5.4"}}}} =
             post_json(port, "/api/workbench/sessions/#{URI.encode(session_key)}/model", %{
               "model" => "reset"
             })

    assert Session.model_override(Session.load(session_key, workspace: workspace)) == nil
  end

  test "serves visual config API and writes structured config changes", %{
    workspace: workspace
  } do
    config_path = Path.join(workspace, "config.json")
    assert :ok = Config.save_map(config_panel_config(workspace), config_path: config_path)

    pid =
      start_server!(
        snapshot(workspace,
          config_path: config_path,
          config: Config.load(config_path: config_path)
        )
      )

    %{running: true, port: port} = Server.status(pid)

    assert {200, %{"config" => config}} = get_json(port, "/api/workbench/config")
    assert config["config_path"] == config_path
    assert "server_side_then_recent" in config["context_strategies"]
    assert config["provider_type_guides"]["openai-codex"]["requires"] != []
    assert [%{"id" => "feishu_ops", "app_secret" => %{"mode" => "env"}}] = config["channels"]
    assert config["channels"] |> hd() |> Map.fetch!("streaming") == true
    assert config["channels"] |> hd() |> get_in(["app_secret", "display_value"]) == "******"
    openai_env = Enum.find(config["providers"], &(&1["key"] == "openai-env"))
    assert get_in(openai_env, ["api_key", "display_value"]) == "******"

    assert Jason.encode!(config) =~ "******"
    assert Jason.encode!(config) =~ "FEISHU_APP_SECRET"
    refute Jason.encode!(config) =~ "sk-existing"

    assert {200, %{"config" => config, "runtime_reload" => %{"status" => reload_status}}} =
             request_json(port, "PUT", "/api/workbench/config/providers/kimi", %{
               "type" => "openai-compatible",
               "base_url" => "https://api.moonshot.cn/v1",
               "api_key_mode" => "literal",
               "api_key_value" => "sk-kimi"
             })

    assert reload_status in ["reloaded", "failed"]
    assert Enum.any?(config["providers"], &(&1["key"] == "kimi"))
    assert {:ok, raw} = Config.read_map(config_path: config_path)
    assert get_in(raw, ["provider", "providers", "kimi", "api_key"]) == "sk-kimi"

    assert {200, %{"config" => config}} =
             request_json(port, "PUT", "/api/workbench/config/models/kimi-thinking", %{
               "provider" => "kimi",
               "id" => "kimi-k2-thinking",
               "context_window" => "131072",
               "auto_compact_token_limit" => "96000",
               "context_strategy" => "server_side_then_recent"
             })

    assert Enum.any?(config["models"], &(&1["key"] == "kimi-thinking"))

    assert {400, %{"error" => error}} =
             request_json(port, "PUT", "/api/workbench/config/models/local", %{
               "provider" => "ollama-local",
               "id" => "llama3.1",
               "context_strategy" => "freeform"
             })

    assert error =~ "context_strategy"

    assert {200, %{"config" => config}} =
             request_json(port, "PATCH", "/api/workbench/config/model-roles", %{
               "default_model" => "kimi-thinking",
               "cheap_model" => "local"
             })

    assert config["model_roles"]["default_model"] == "kimi-thinking"

    assert {200, %{"config" => config}} =
             request_json(port, "PUT", "/api/workbench/config/channels/discord_ops", %{
               "type" => "discord",
               "enabled" => true,
               "streaming" => false,
               "token_mode" => "literal",
               "token_value" => "discord-token",
               "allow_from" => "123\n456",
               "show_table_as" => "embed"
             })

    assert Enum.any?(config["channels"], fn channel ->
             channel["id"] == "discord_ops" and channel["token"]["configured"] == true and
               channel["token"]["display_value"] == "******" and
               channel["allow_from"] == ["123", "456"] and
               channel["show_table_as"] == "embed"
           end)

    assert {400, %{"error" => error}} =
             request_json(port, "DELETE", "/api/workbench/config/providers/kimi")

    assert error =~ "still used by models"
  end

  test "config API rejects invalid enabled channels without writing", %{workspace: workspace} do
    config_path = Path.join(workspace, "config.json")
    original = config_panel_config(workspace)
    assert :ok = Config.save_map(original, config_path: config_path)

    pid =
      start_server!(
        snapshot(workspace,
          config_path: config_path,
          config: Config.load(config_path: config_path)
        )
      )

    %{running: true, port: port} = Server.status(pid)

    assert {400, %{"error" => error}} =
             request_json(port, "PUT", "/api/workbench/config/channels/feishu_bad", %{
               "type" => "feishu",
               "enabled" => true,
               "app_id" => "cli_feishu_app"
             })

    assert error =~ "requires app_secret"
    assert {:ok, raw} = Config.read_map(config_path: config_path)
    assert raw == original

    assert {400, %{"error" => error}} =
             request_json(port, "PUT", "/api/workbench/config/channels/telegram_bad", %{
               "type" => "telegram",
               "enabled" => true,
               "token_mode" => "literal",
               "token_value" => "telegram-token"
             })

    assert error =~ "channel type"
    assert error =~ "not supported"
    assert {:ok, raw} = Config.read_map(config_path: config_path)
    assert raw == original
  end

  test "config API preserves raw-valid saves when runtime reload fails", %{workspace: workspace} do
    config_path = Path.join(workspace, "config.json")
    original = config_panel_config(workspace)
    assert :ok = Config.save_map(original, config_path: config_path)

    pid =
      start_server!(
        snapshot(workspace,
          config_path: config_path,
          config: Config.load(config_path: config_path)
        )
      )

    %{running: true, port: port} = Server.status(pid)
    runtime_pid = Process.whereis(Runtime) || flunk("Runtime process is not running")
    old_runtime_state = :sys.get_state(runtime_pid)

    on_exit(fn ->
      if Process.alive?(runtime_pid) do
        :sys.replace_state(runtime_pid, fn _state -> old_runtime_state end)
      end
    end)

    :sys.replace_state(runtime_pid, fn state ->
      %{state | prompt_builder: fn _opts -> {:error, :forced_reload_failure} end}
    end)

    assert {200,
            %{
              "runtime_reload" => %{
                "status" => "failed",
                "applied" => false,
                "reason" => reason
              }
            }} =
             request_json(port, "PUT", "/api/workbench/config/providers/kimi", %{
               "type" => "openai-compatible",
               "base_url" => "https://api.moonshot.cn/v1",
               "api_key_mode" => "literal",
               "api_key_value" => "sk-kimi"
             })

    assert reason =~ "forced_reload_failure"
    assert {:ok, raw} = Config.read_map(config_path: config_path)
    refute raw == original
    assert get_in(raw, ["provider", "providers", "kimi", "api_key"]) == "sk-kimi"
  end

  test "serves self evolution energy candidates detail and confirmed actions", %{
    workspace: workspace
  } do
    File.mkdir_p!(Path.join(workspace, "memory"))

    assert {:ok, evidence} =
             Nex.Agent.ControlPlane.Log.warning(
               "runner.tool.call.failed",
               %{"tool_name" => "read", "error_summary" => "missing file"},
               workspace: workspace,
               run_id: "run-evo"
             )

    for index <- 1..501 do
      assert {:ok, _} =
               ControlPlaneStore.append(
                 %{"tag" => "workbench.test.filler", "attrs" => %{"index" => index}},
                 workspace: workspace
               )
    end

    proposed_at = ControlPlaneStore.timestamp()

    assert {:ok, _} =
             Nex.Agent.ControlPlane.Log.info(
               "evolution.candidate.proposed",
               %{
                 "id" => "cand_ui",
                 "kind" => "code_hint",
                 "summary" => "Tighten read error handling",
                 "rationale" => "Repeated read failures need bounded handling.",
                 "evidence_ids" => [evidence["id"]],
                 "risk" => "medium",
                 "requires_owner_approval" => true,
                 "created_at" => proposed_at
               },
               workspace: workspace
             )

    pid = start_server!(snapshot(workspace))
    %{running: true, port: port} = Server.status(pid)

    assert {200,
            %{
              "energy" => %{"current" => 60, "capacity" => 100, "mode" => "normal"},
              "candidates" => [
                %{
                  "candidate_id" => "cand_ui",
                  "summary" => "Tighten read error handling",
                  "risk" => "medium",
                  "created_at" => ^proposed_at
                }
              ]
            }} = get_json(port, "/api/workbench/evolution")

    assert {200,
            %{
              "candidate" => %{
                "candidate_id" => "cand_ui",
                "evidence_ids" => [evidence_id],
                "evidence" => [%{"id" => evidence_id, "tag" => "runner.tool.call.failed"}],
                "missing_evidence_ids" => []
              }
            }} = get_json(port, "/api/workbench/evolution/candidates/cand_ui")

    assert evidence_id == evidence["id"]

    assert {400, %{"error" => "confirmation is required" <> _}} =
             post_json(port, "/api/workbench/evolution/candidates/cand_ui/discard", %{})

    assert {:ok, %{"status" => "pending"}} = Evolution.candidate("cand_ui", workspace: workspace)

    assert {200, %{"result" => %{"decision" => "rejected"}}} =
             post_json(port, "/api/workbench/evolution/candidates/cand_ui/discard", %{
               "confirm" => true,
               "decision_reason" => "not worth doing"
             })

    assert {:ok, %{"status" => "rejected"}} = Evolution.candidate("cand_ui", workspace: workspace)

    observations =
      Query.query(%{"tag_prefix" => "workbench.bridge.call.", "limit" => 10},
        workspace: workspace
      )

    assert Enum.any?(observations, &(&1["tag"] == "workbench.bridge.call.failed"))
    assert Enum.any?(observations, &(&1["tag"] == "workbench.bridge.call.finished"))
  end

  test "self evolution apply uses candidate execution lane", %{workspace: workspace} do
    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    assert {:ok, _} =
             Nex.Agent.ControlPlane.Log.info(
               "evolution.candidate.proposed",
               %{
                 "id" => "cand_memory_apply",
                 "kind" => "memory_candidate",
                 "summary" => "Remember workbench confirmation rule",
                 "rationale" => "Owner wants action confirmation in Workbench.",
                 "evidence_ids" => [],
                 "risk" => "low",
                 "requires_owner_approval" => true,
                 "created_at" => ControlPlaneStore.timestamp()
               },
               workspace: workspace
             )

    pid = start_server!(snapshot(workspace))
    %{running: true, port: port} = Server.status(pid)

    assert {200,
            %{
              "result" => %{
                "decision" => "approved",
                "mode" => "apply",
                "apply" => %{"status" => "applied"}
              }
            }} =
             post_json(port, "/api/workbench/evolution/candidates/cand_memory_apply/apply", %{
               "confirm" => true,
               "decision_reason" => "approved from workbench"
             })

    assert {:ok, %{"status" => "applied"}} =
             Evolution.candidate("cand_memory_apply", workspace: workspace)

    assert File.read!(Path.join(workspace, "memory/MEMORY.md")) =~
             "Remember workbench confirmation rule"
  end

  test "rejects non-loopback runtime hosts", %{workspace: workspace} do
    pid =
      start_server!(%Snapshot{
        workspace: workspace,
        workbench: %{
          runtime: %{"enabled" => true, "host" => "0.0.0.0", "port" => 0},
          apps: [],
          diagnostics: [],
          hash: ""
        }
      })

    assert %{enabled: true, running: false, last_error: error} = Server.status(pid)
    assert error =~ "invalid workbench runtime"
  end

  test "rejects oversized HTTP request bodies before routing", %{workspace: workspace} do
    pid = start_server!(snapshot(workspace))
    %{running: true, port: port} = Server.status(pid)

    request = [
      "POST /api/workbench/permissions/notes/grant HTTP/1.1\r\n",
      "Host: 127.0.0.1\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: 1048577\r\n",
      "\r\n"
    ]

    assert {413, body} = raw_http(port, request)
    assert body =~ "request body too large"
  end

  defp snapshot(workspace, opts \\ []) do
    %{"apps" => apps, "diagnostics" => diagnostics} = Store.load_all(workspace: workspace)

    %Snapshot{
      config: Keyword.get(opts, :config, Config.default()),
      config_path: Keyword.get(opts, :config_path),
      workspace: workspace,
      workbench: %{
        runtime: %{"enabled" => true, "host" => "127.0.0.1", "port" => 0},
        apps: Enum.map(apps, &Nex.Agent.Workbench.AppManifest.to_map/1),
        diagnostics: diagnostics,
        hash: "test"
      }
    }
  end

  defp start_server!(%Snapshot{} = snapshot) do
    start_supervised!(
      {Server, name: nil, subscribe?: false, runtime_provider: fn -> {:ok, snapshot} end}
    )
  end

  defp get_json(port, path) do
    url = "http://127.0.0.1:#{port}#{path}" |> String.to_charlist()

    {:ok, {{_version, status, _reason}, _headers, body}} =
      :httpc.request(:get, {url, []}, [], body_format: :binary)

    {status, Jason.decode!(body)}
  end

  defp get_raw(port, path) do
    url = "http://127.0.0.1:#{port}#{path}" |> String.to_charlist()

    {:ok, {{_version, status, _reason}, _headers, body}} =
      :httpc.request(:get, {url, []}, [], body_format: :binary)

    {status, body}
  end

  defp get_raw_with_headers(port, path) do
    url = "http://127.0.0.1:#{port}#{path}" |> String.to_charlist()

    {:ok, {{_version, status, _reason}, headers, body}} =
      :httpc.request(:get, {url, []}, [], body_format: :binary)

    {status, normalize_headers(headers), body}
  end

  defp post_json(port, path, payload) do
    url = "http://127.0.0.1:#{port}#{path}" |> String.to_charlist()
    body = Jason.encode!(payload)

    {:ok, {{_version, status, _reason}, _headers, response_body}} =
      :httpc.request(:post, {url, [], ~c"application/json", body}, [], body_format: :binary)

    {status, Jason.decode!(response_body)}
  end

  defp request_json(port, method, path, payload \\ %{}) do
    body = Jason.encode!(payload)

    request = [
      "#{method} #{path} HTTP/1.1\r\n",
      "Host: 127.0.0.1\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "\r\n",
      body
    ]

    {status, response_body} = raw_http(port, request)
    {status, Jason.decode!(response_body)}
  end

  defp raw_http(port, request) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    :gen_tcp.close(socket)

    [head, body] = String.split(response, "\r\n\r\n", parts: 2)

    ["HTTP/1.1", status, _reason] =
      head |> String.split("\r\n") |> hd() |> String.split(" ", parts: 3)

    {String.to_integer(status), body}
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {key, value} ->
      {key |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp header_value(headers, key), do: Map.get(headers, String.downcase(key))

  defp model_config do
    %Config{
      provider: %{
        "providers" => %{
          "openai-codex" => %{
            "type" => "openai-codex",
            "base_url" => "https://chatgpt.com/backend-api/codex"
          },
          "hy3-tencent" => %{
            "type" => "openai-compatible",
            "base_url" => "https://hy3.example.test/v1"
          }
        }
      },
      model: %{
        "default_model" => "gpt-5.4",
        "models" => %{
          "gpt-5.4" => %{
            "provider" => "openai-codex",
            "id" => "gpt-5.4",
            "context_window" => 128_000
          },
          "hy3-preview" => %{
            "provider" => "hy3-tencent",
            "id" => "hy3-preview",
            "context_window" => 64_000
          }
        }
      }
    }
  end

  defp config_panel_config(workspace) do
    %{
      "max_iterations" => 40,
      "workspace" => workspace,
      "gateway" => %{"port" => 18_790},
      "provider" => %{
        "providers" => %{
          "ollama-local" => %{
            "type" => "ollama",
            "base_url" => "http://localhost:11434",
            "api_key" => nil
          },
          "openai-env" => %{
            "type" => "openai-compatible",
            "base_url" => "https://api.openai.com/v1",
            "api_key" => "sk-existing"
          }
        }
      },
      "model" => %{
        "default_model" => "local",
        "cheap_model" => "local",
        "models" => %{"local" => %{"provider" => "ollama-local", "id" => "llama3.1"}}
      },
      "channel" => %{
        "feishu_ops" => %{
          "type" => "feishu",
          "enabled" => false,
          "streaming" => true,
          "app_id" => "cli_feishu_app",
          "app_secret" => %{"env" => "FEISHU_APP_SECRET"}
        }
      },
      "subagents" => %{"profiles" => %{}},
      "tools" => %{}
    }
  end
end
