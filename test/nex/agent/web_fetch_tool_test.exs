defmodule Nex.Agent.WebFetchToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.WebFetch

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

  test "web_fetch passes proxy settings through Req options" do
    System.put_env("https_proxy", "http://127.0.0.1:7890")
    caller = self()

    http_get = fn url, opts ->
      send(caller, {:http_get, url, opts})

      {:ok,
       %{
         status: 200,
         body: "<html><body><main>proxied github content</main></body></html>",
         headers: [{"content-type", "text/html; charset=utf-8"}]
       }}
    end

    assert {:ok, content} =
             WebFetch.execute(
               %{"url" => "https://github.com/Core-Mate/busydog-bdp/blob/main/skill.md"},
               %{http_get: http_get}
             )

    assert content =~ "Source: https://github.com/Core-Mate/busydog-bdp/blob/main/skill.md"
    assert content =~ "proxied github content"

    assert_receive {:http_get, "https://github.com/Core-Mate/busydog-bdp/blob/main/skill.md",
                    opts}

    assert opts[:receive_timeout] == 30_000
    assert opts[:connect_options][:proxy] == {:http, "127.0.0.1", 7890, []}
  end
end
