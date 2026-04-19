defmodule Nex.Agent.WSTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.WS

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
    previous = Map.new(@proxy_keys, fn key -> {key, System.get_env(key)} end)
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

  test "connect adds proxy option for wss urls" do
    System.put_env("https_proxy", "http://127.0.0.1:7890")

    assert {:error, {:captured_opts, opts}} =
             WS.connect("wss://gateway.discord.gg/?v=10", connect_http_fun: capture_connect_fun())

    assert opts[:proxy] == {:http, "127.0.0.1", 7890, []}
    assert opts[:protocols] == [:http1]
  end

  test "connect omits proxy option when no_proxy matches" do
    System.put_env("https_proxy", "http://127.0.0.1:7890")
    System.put_env("no_proxy", "gateway.discord.gg")

    assert {:error, {:captured_opts, opts}} =
             WS.connect("wss://gateway.discord.gg/?v=10", connect_http_fun: capture_connect_fun())

    refute Keyword.has_key?(opts, :proxy)
  end

  defp capture_connect_fun do
    fn _scheme, _host, _port, opts -> {:error, {:captured_opts, opts}} end
  end
end
