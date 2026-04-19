defmodule Nex.Agent.HTTPTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{HTTP, RunControl}

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
               HTTP.request(:put, "https://discord.com/api/v10/channels/1/messages/2", headers: [])

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

    workspace = Path.join(System.tmp_dir!(), "nex-agent-http-cancel-#{System.unique_integer([:positive])}")
    session_key = "feishu:chat-http-cancel"

    assert {:ok, run} = RunControl.start_owner(workspace, session_key, %{})

    me = self()
    old_get = Application.get_env(:nex_agent, :http_test_req_get)

    Application.put_env(:nex_agent, :http_test_req_get, fn _url, _opts ->
      send(me, :http_req_started)
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

      assert_receive :http_req_started, 1_000
      assert {:ok, %{cancelled?: true, run_id: _run_id}} = RunControl.cancel_owner(workspace, session_key, :user_stop)

      assert_receive {:http_cancel_result, {:error, :cancelled}}, 2_000
      Task.shutdown(task, :brutal_kill)
    after
      case old_get do
        nil -> Application.delete_env(:nex_agent, :http_test_req_get)
        value -> Application.put_env(:nex_agent, :http_test_req_get, value)
      end
    end
  end
end
