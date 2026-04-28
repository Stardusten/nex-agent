defmodule Nex.Agent.Workbench.AssetsTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.ControlPlane.Query
  alias Nex.Agent.Workbench.{Assets, Store}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-workbench-assets-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(workspace) end)

    create_app!(workspace)
    {:ok, workspace: workspace}
  end

  test "app frame reads default index entry and injects Nex SDK bootstrap", %{
    workspace: workspace
  } do
    assert {:ok, html} = Assets.app_frame("demo", workspace: workspace)

    assert html =~ "<h1>Hello</h1>"
    assert html =~ ~s(<base href="/app-assets/demo/">)
    assert html =~ "window.Nex"
    assert html =~ "workbench.bridge.request"

    assert [observation] =
             Query.query(%{"tag" => "workbench.app.frame.served", "limit" => 1},
               workspace: workspace
             )

    assert observation["attrs"]["app_id"] == "demo"
    assert observation["attrs"]["entry"] == "index.html"
  end

  test "missing entry becomes bounded iframe error instead of crash", %{workspace: workspace} do
    assert {:ok, _} =
             Store.save(
               %{"id" => "missing-entry", "title" => "Missing", "entry" => "missing.html"},
               workspace: workspace
             )

    assert {:error, 200, html} = Assets.app_frame("missing-entry", workspace: workspace)
    assert html =~ "App entry unavailable"
    assert html =~ "asset file is missing"

    assert [observation] =
             Query.query(%{"tag" => "workbench.app.frame.failed", "limit" => 1},
               workspace: workspace
             )

    assert observation["attrs"]["app_id"] == "missing-entry"
  end

  test "serves app assets with bounded content types", %{workspace: workspace} do
    assert {:ok, %{content_type: "application/javascript", body: js}} =
             Assets.asset("demo", "app.js", workspace: workspace)

    assert js =~ "hello"

    assert {:ok, %{content_type: "text/css", body: css}} =
             Assets.asset("demo", "style.css", workspace: workspace)

    assert css =~ "color"
  end

  test "rejects escaping special and oversized asset paths", %{workspace: workspace} do
    app_dir = Path.join([workspace, "workbench", "apps", "demo"])
    File.mkdir_p!(Path.join(app_dir, "nested"))
    File.write!(Path.join(app_dir, "large.txt"), :binary.copy("x", 2 * 1024 * 1024 + 1))

    assert {:error, 400, "asset path must not contain .. segments"} =
             Assets.asset("demo", "../secret.txt", workspace: workspace)

    assert {:error, 400, "asset path must be relative"} =
             Assets.asset("demo", "/tmp/secret.txt", workspace: workspace)

    assert {:error, 400, "nex.app.json is not served as an app asset"} =
             Assets.asset("demo", "nex.app.json", workspace: workspace)

    assert {:error, 400, "asset path is a directory"} =
             Assets.asset("demo", "nested", workspace: workspace)

    assert {:error, 400, "asset file exceeds 2MB limit"} =
             Assets.asset("demo", "large.txt", workspace: workspace)

    assert {:error, 404, "manifest file is missing"} =
             Assets.asset("unknown-app", "index.html", workspace: workspace)
  end

  defp create_app!(workspace) do
    assert {:ok, _} =
             Store.save(
               %{
                 "id" => "demo",
                 "title" => "Demo",
                 "permissions" => ["permissions:read", "observe:read"]
               },
               workspace: workspace
             )

    app_dir = Path.join([workspace, "workbench", "apps", "demo"])

    File.write!(
      Path.join(app_dir, "index.html"),
      "<!doctype html><html><head><title>Demo</title></head><body><h1>Hello</h1></body></html>"
    )

    File.write!(Path.join(app_dir, "app.js"), "console.log('hello');")
    File.write!(Path.join(app_dir, "style.css"), "body { color: #20251f; }")
  end
end
