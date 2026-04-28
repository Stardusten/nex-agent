defmodule Nex.Agent.Workbench.BridgeTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.ControlPlane.{Log, Query}
  alias Nex.Agent.Workbench.{Bridge, Permissions, Store}
  require Log

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-workbench-bridge-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "denies calls when permission is not declared or granted", %{workspace: workspace} do
    create_app!(workspace, ["permissions:read"])

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "permission_denied",
               "message" => "permission is not declared" <> _
             }
           } =
             Bridge.call(
               "demo",
               %{"call_id" => "call_1", "method" => "observe.summary", "params" => %{}},
               workspace: workspace
             )

    assert %{
             "ok" => false,
             "error" => %{"code" => "permission_denied", "message" => "permission is not granted"}
           } =
             Bridge.call(
               "demo",
               %{"call_id" => "call_2", "method" => "permissions.current", "params" => %{}},
               workspace: workspace
             )

    observations =
      Query.query(%{"tag_prefix" => "workbench.bridge.call.", "limit" => 10},
        workspace: workspace
      )

    assert Enum.count(observations, &(&1["tag"] == "workbench.bridge.call.started")) == 2
    assert Enum.count(observations, &(&1["tag"] == "workbench.bridge.call.denied")) == 2
  end

  test "executes permissions and observe methods after owner grant", %{workspace: workspace} do
    create_app!(workspace, ["permissions:read", "observe:read"])
    assert {:ok, _} = Permissions.grant("demo", "permissions:read", workspace: workspace)
    assert {:ok, _} = Permissions.grant("demo", "observe:read", workspace: workspace)

    assert {:ok, _} =
             Log.warning(
               "runner.tool.call.failed",
               %{"tool_name" => "read", "summary" => "missing"},
               workspace: workspace,
               run_id: "run-bridge",
               session_key: "session-bridge",
               channel: "feishu"
             )

    assert %{"ok" => true, "result" => %{"app_id" => "demo", "granted_permissions" => granted}} =
             Bridge.call(
               "demo",
               %{
                 "call_id" => "call_permissions",
                 "method" => "permissions.current",
                 "params" => %{}
               },
               workspace: workspace
             )

    assert "permissions:read" in granted

    assert %{"ok" => true, "result" => %{"recent" => recent}} =
             Bridge.call(
               "demo",
               %{
                 "call_id" => "call_summary",
                 "method" => "observe.summary",
                 "params" => %{"limit" => 5}
               },
               workspace: workspace
             )

    assert Enum.any?(recent, &(&1["tag"] == "runner.tool.call.failed"))

    assert %{
             "ok" => true,
             "result" => %{
               "filters" => filters,
               "observations" => [observation]
             }
           } =
             Bridge.call(
               "demo",
               %{
                 "call_id" => "call_query",
                 "method" => "observe.query",
                 "params" => %{"tag_prefix" => "runner.tool.", "tool" => "read", "limit" => 5}
               },
               workspace: workspace
             )

    assert filters["tag_prefix"] == "runner.tool."
    assert filters["tool"] == "read"
    assert filters["limit"] == 5
    assert observation["tag"] == "runner.tool.call.failed"

    observations =
      Query.query(%{"tag" => "workbench.bridge.call.finished", "limit" => 10},
        workspace: workspace
      )

    assert Enum.count(observations) == 3
  end

  test "rejects unknown methods and unsupported params without exposing arbitrary calls", %{
    workspace: workspace
  } do
    create_app!(workspace, ["observe:read"])
    assert {:ok, _} = Permissions.grant("demo", "observe:read", workspace: workspace)

    assert %{"ok" => false, "error" => %{"code" => "unknown_method"}} =
             Bridge.call(
               "demo",
               %{"call_id" => "call_unknown", "method" => "tools.call", "params" => %{}},
               workspace: workspace
             )

    assert %{
             "ok" => false,
             "error" => %{"code" => "bad_params", "message" => "unsupported param" <> _}
           } =
             Bridge.call(
               "demo",
               %{
                 "call_id" => "call_bad_params",
                 "method" => "observe.query",
                 "params" => %{"path" => "/tmp/secret", "limit" => 5}
               },
               workspace: workspace
             )

    observations =
      Query.query(%{"tag" => "workbench.bridge.call.failed", "limit" => 10},
        workspace: workspace
      )

    assert Enum.count(observations) == 2
  end

  defp create_app!(workspace, permissions) do
    assert {:ok, _} =
             Store.save(
               %{
                 "id" => "demo",
                 "title" => "Demo",
                 "permissions" => permissions
               },
               workspace: workspace
             )
  end
end
