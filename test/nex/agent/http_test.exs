defmodule Nex.Agent.HTTPTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.HTTP

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
end
