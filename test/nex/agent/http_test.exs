defmodule Nex.Agent.HTTPTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{HTTP, RunControl}
  alias Nex.Agent.ControlPlane.Query, as: ControlPlaneQuery

  @proxy_keys [
    "HTTP_PROXY",
    "http_proxy",
    "HTTPS_PROXY",
    "https_proxy",
    "ALL_PROXY",
    "all_proxy",
    "NO_PROXY",
    "no_proxy"
  ]

  setup do
    previous =
      Map.new(@proxy_keys, fn key ->
        {key, System.get_env(key)}
      end)

    Enum.each(@proxy_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(@proxy_keys, fn key ->
        case Map.get(previous, key) do
          nil -> System.delete_env(key)
          value -> System.put_env(key, value)
        end
      end)
    end)

    :ok
  end

  test "uses https proxy for https urls" do
    System.put_env("https_proxy", "http://127.0.0.1:7890")

    opts = HTTP.maybe_add_proxy([receive_timeout: 1_000], "https://github.com/example/repo")

    assert opts[:receive_timeout] == 1_000
    assert opts[:connect_options][:proxy] == {:http, "127.0.0.1", 7890, []}
  end

  test "falls back to all_proxy when scheme-specific proxy is absent" do
    System.put_env("all_proxy", "http://127.0.0.1:7891")

    opts = HTTP.maybe_add_proxy([], "https://github.com/example/repo")

    assert opts[:connect_options][:proxy] == {:http, "127.0.0.1", 7891, []}
  end

  test "respects no_proxy and bypasses proxy for matching hosts" do
    System.put_env("https_proxy", "http://127.0.0.1:7890")
    System.put_env("no_proxy", "github.com,.internal.example")

    assert HTTP.maybe_add_proxy([], "https://github.com/example/repo") == []
    assert HTTP.maybe_add_proxy([], "https://api.internal.example/health") == []
  end

  test "respects no_proxy for ipv6 literals" do
    System.put_env("https_proxy", "http://127.0.0.1:7890")
    System.put_env("no_proxy", "[::1]")

    assert HTTP.maybe_add_proxy([], "https://[::1]/health") == []
  end

  test "only bypasses proxy when a no_proxy port matches" do
    System.put_env("https_proxy", "http://127.0.0.1:7890")
    System.put_env("no_proxy", "localhost:4000")

    assert HTTP.maybe_add_proxy([], "https://localhost:4000/health") == []

    assert HTTP.maybe_add_proxy([], "https://localhost:5000/health")[:connect_options][:proxy] ==
             {:http, "127.0.0.1", 7890, []}
  end

  test "preserves existing connect options while adding proxy" do
    System.put_env("https_proxy", "http://127.0.0.1:7890")

    opts =
      HTTP.maybe_add_proxy([connect_options: [timeout: 2_000]], "https://github.com/example/repo")

    assert opts[:connect_options][:timeout] == 2_000
    assert opts[:connect_options][:proxy] == {:http, "127.0.0.1", 7890, []}
  end

  test "maps wss proxy lookup to https proxy settings" do
    System.put_env("https_proxy", "http://127.0.0.1:7890")

    assert HTTP.proxy_tuple_for("wss://gateway.discord.gg/?v=10") ==
             {:http, "127.0.0.1", 7890, []}
  end

  test "maps ws proxy lookup to http proxy settings" do
    System.put_env("http_proxy", "http://127.0.0.1:7892")

    assert HTTP.proxy_tuple_for("ws://localhost:4000/socket") ==
             {:http, "127.0.0.1", 7892, []}
  end

  test "respects no_proxy for websocket urls" do
    System.put_env("https_proxy", "http://127.0.0.1:7890")
    System.put_env("no_proxy", "gateway.discord.gg")

    assert HTTP.proxy_tuple_for("wss://gateway.discord.gg/?v=10") == nil
  end

  test "request/3 injects proxy settings for https urls" do
    System.put_env("https_proxy", "http://127.0.0.1:7890")

    me = self()

    old_put = Application.get_env(:nex_agent, :http_test_req_put)

    Application.put_env(:nex_agent, :http_test_req_put, fn url, opts ->
      send(me, {:req_put, url, opts})
      {:ok, %{status: 204}}
    end)

    try do
      assert {:ok, %{status: 204}} =
               HTTP.request(:put, "https://discord.com/api/v10/channels/1/messages/2",
                 headers: []
               )

      assert_receive {:req_put, "https://discord.com/api/v10/channels/1/messages/2", opts}
      assert opts[:connect_options][:proxy] == {:http, "127.0.0.1", 7890, []}
      assert opts[:retry] == false
    after
      case old_put do
        nil -> Application.delete_env(:nex_agent, :http_test_req_put)
        value -> Application.put_env(:nex_agent, :http_test_req_put, value)
      end
    end
  end

  test "request/3 aborts a blocked request when cancel_ref is cancelled" do
    if Process.whereis(RunControl) == nil do
      start_supervised!({RunControl, name: RunControl})
    end

    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-http-cancel-#{System.unique_integer([:positive])}")

    session_key = "feishu:chat-http-cancel"

    assert {:ok, run} = RunControl.start_owner(workspace, session_key, %{})

    me = self()
    old_get = Application.get_env(:nex_agent, :http_test_req_get)

    Application.put_env(:nex_agent, :http_test_req_get, fn _url, opts ->
      send(me, {:http_req_started, opts})
      Process.sleep(5_000)
      {:ok, %{status: 200, body: "late"}}
    end)

    try do
      task =
        Task.async(fn ->
          result =
            HTTP.get("https://example.com/slow",
              receive_timeout: 10_000,
              cancel_ref: run.cancel_ref
            )

          send(me, {:http_cancel_result, result})
          result
        end)

      assert_receive {:http_req_started, req_opts}, 1_000
      refute Keyword.has_key?(req_opts, :cancel_ref)

      assert {:ok, %{cancelled?: true, run_id: _run_id}} =
               RunControl.cancel_owner(workspace, session_key, :user_stop)

      assert_receive {:http_cancel_result, {:error, :cancelled}}, 2_000
      Task.shutdown(task, :brutal_kill)
    after
      case old_get do
        nil -> Application.delete_env(:nex_agent, :http_test_req_get)
        value -> Application.put_env(:nex_agent, :http_test_req_get, value)
      end
    end
  end

  test "request/3 records lifecycle observations without leaking query or internal opts" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-http-observe-#{System.unique_integer([:positive])}"
      )

    me = self()
    old_get = Application.get_env(:nex_agent, :http_test_req_get)

    Application.put_env(:nex_agent, :http_test_req_get, fn url, opts ->
      send(me, {:req_get, url, opts})
      {:ok, %{status: 202, body: "ok"}}
    end)

    try do
      assert {:ok, %{status: 202}} =
               HTTP.get("https://example.com/path?token=secret",
                 cancel_ref: make_ref(),
                 observe_context: %{workspace: workspace, run_id: "run_http"}
               )

      assert_receive {:req_get, _url, opts}
      refute Keyword.has_key?(opts, :cancel_ref)
      refute Keyword.has_key?(opts, :observe_context)

      assert [started] =
               ControlPlaneQuery.query(%{"tag" => "http.request.started"}, workspace: workspace)

      assert started["context"]["run_id"] == "run_http"
      assert started["attrs"]["host"] == "example.com"
      assert started["attrs"]["path"] == "/path"
      refute inspect(started) =~ "token=secret"

      assert [finished] =
               ControlPlaneQuery.query(%{"tag" => "http.request.finished"}, workspace: workspace)

      assert finished["attrs"]["status"] == 202
    after
      case old_get do
        nil -> Application.delete_env(:nex_agent, :http_test_req_get)
        value -> Application.put_env(:nex_agent, :http_test_req_get, value)
      end

      File.rm_rf!(workspace)
    end
  end

  test "request/3 converts request task exceptions into structured errors and observations" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-http-exception-#{System.unique_integer([:positive])}"
      )

    old_get = Application.get_env(:nex_agent, :http_test_req_get)

    Application.put_env(:nex_agent, :http_test_req_get, fn _url, _opts ->
      raise ArgumentError, "boom"
    end)

    try do
      assert {:error, {:exception, "ArgumentError", "boom"}} =
               HTTP.get("https://example.com/fail",
                 observe_context: %{workspace: workspace, run_id: "run_http_exception"}
               )

      assert [failed] =
               ControlPlaneQuery.query(%{"tag" => "http.request.failed"}, workspace: workspace)

      assert failed["context"]["run_id"] == "run_http_exception"
      assert failed["attrs"]["reason_type"] == "ArgumentError"
    after
      case old_get do
        nil -> Application.delete_env(:nex_agent, :http_test_req_get)
        value -> Application.put_env(:nex_agent, :http_test_req_get, value)
      end

      File.rm_rf!(workspace)
    end
  end
end
