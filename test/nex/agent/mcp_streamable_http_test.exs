defmodule Nex.Agent.MCPStreamableHTTPTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Interface.MCP
  alias Nex.Agent.Runtime.Config

  setup do
    previous_post = Application.get_env(:nex_agent, :http_test_req_post)
    previous_get = Application.get_env(:nex_agent, :http_test_req_get)
    previous_secret = System.get_env("NEX_AGENT_MCP_STREAMABLE_HTTP_SECRET")

    on_exit(fn ->
      restore_env(:http_test_req_post, previous_post)
      restore_env(:http_test_req_get, previous_get)

      case previous_secret do
        nil -> System.delete_env("NEX_AGENT_MCP_STREAMABLE_HTTP_SECRET")
        value -> System.put_env("NEX_AGENT_MCP_STREAMABLE_HTTP_SECRET", value)
      end
    end)

    :ok
  end

  test "streamable HTTP transport completes initialize, list_tools, and call_tool over POST" do
    parent = self()
    endpoint = "https://mcp.example.test/mcp"

    Application.put_env(:nex_agent, :http_test_req_get, fn url, _opts ->
      send(parent, {:unexpected_get, url})
      {:ok, %{status: 405, headers: [{"content-type", "text/plain"}], body: ""}}
    end)

    Application.put_env(:nex_agent, :http_test_req_post, fn url, opts ->
      request = Keyword.fetch!(opts, :json)
      headers = Keyword.fetch!(opts, :headers)
      send(parent, {:post, url, request, headers})

      case request_method(request) do
        "initialize" ->
          json_response(request, %{"capabilities" => %{}, "serverInfo" => %{"name" => "fake"}},
            headers: [{"content-type", "application/json"}, {"Mcp-Session-Id", "sess-123"}]
          )

        "notifications/initialized" ->
          {:ok, %{status: 202, headers: [], body: ""}}

        "tools/list" ->
          json_response(request, %{
            "tools" => [%{"name" => "echo", "description" => "Echo"}]
          })

        "tools/call" ->
          json_response(request, %{
            "content" => [%{"type" => "text", "text" => "pong"}]
          })
      end
    end)

    {:ok, pid} =
      MCP.start_link(
        transport: "streamable-http",
        url: endpoint,
        headers: %{"Authorization" => "Bearer test-token"}
      )

    assert :ok = MCP.initialize(pid)

    assert_receive {:post, ^endpoint, %{method: "initialize"}, init_headers}
    assert header_value(init_headers, "accept") == "application/json, text/event-stream"
    assert header_value(init_headers, "content-type") == "application/json"
    assert header_value(init_headers, "authorization") == "Bearer test-token"
    refute header_value(init_headers, "mcp-session-id")

    assert_receive {:post, ^endpoint, %{method: "notifications/initialized"}, ready_headers}
    assert header_value(ready_headers, "mcp-session-id") == "sess-123"

    assert {:ok, %{"tools" => [%{"name" => "echo"}]}} = MCP.list_tools(pid)
    assert_receive {:post, ^endpoint, %{method: "tools/list"}, list_headers}
    assert header_value(list_headers, "mcp-session-id") == "sess-123"

    assert {:ok, %{"content" => [%{"text" => "pong"}]}} = MCP.call_tool(pid, "echo", %{})
    assert_receive {:post, ^endpoint, %{method: "tools/call"}, call_headers}
    assert header_value(call_headers, "mcp-session-id") == "sess-123"

    refute_received {:unexpected_get, _url}
    assert :ok = MCP.stop(pid)
  end

  test "streamable HTTP transport parses POST SSE responses" do
    parent = self()
    endpoint = "https://mcp.example.test/mcp"

    Application.put_env(:nex_agent, :http_test_req_post, fn url, opts ->
      request = Keyword.fetch!(opts, :json)
      send(parent, {:post, url, request, Keyword.fetch!(opts, :headers)})

      case request_method(request) do
        "initialize" ->
          json_response(request, %{"capabilities" => %{}})

        "notifications/initialized" ->
          {:ok, %{status: 202, headers: [], body: ""}}

        "tools/list" ->
          sse_response(request, %{
            "tools" => [%{"name" => "stream_echo", "description" => "Echo"}]
          })
      end
    end)

    {:ok, pid} = MCP.start_link(transport: "streamable-http", url: endpoint)
    assert :ok = MCP.initialize(pid)

    assert {:ok, %{"tools" => [%{"name" => "stream_echo"}]}} = MCP.list_tools(pid)
    assert_receive {:post, ^endpoint, %{method: "tools/list"}, headers}
    assert header_value(headers, "accept") == "application/json, text/event-stream"

    assert :ok = MCP.stop(pid)
  end

  test "GET SSE 405 is not required for the POST request response path" do
    parent = self()

    Application.put_env(:nex_agent, :http_test_req_get, fn _url, _opts ->
      send(parent, :get_called)
      {:ok, %{status: 405, headers: [{"content-type", "text/plain"}], body: ""}}
    end)

    Application.put_env(:nex_agent, :http_test_req_post, fn _url, opts ->
      request = Keyword.fetch!(opts, :json)

      case request_method(request) do
        "initialize" -> json_response(request, %{"capabilities" => %{}})
        "notifications/initialized" -> {:ok, %{status: 202, headers: [], body: ""}}
        "tools/list" -> json_response(request, %{"tools" => []})
      end
    end)

    {:ok, pid} =
      MCP.start_link(transport: "streamable-http", url: "https://mcp.example.test/mcp")

    assert :ok = MCP.initialize(pid)
    assert {:ok, %{"tools" => []}} = MCP.list_tools(pid)
    refute_received :get_called
    assert :ok = MCP.stop(pid)
  end

  test "streamable HTTP transport renders plugin templates at request boundary" do
    parent = self()
    workspace = "/tmp/nex-agent-mcp-http-template"
    endpoint = "https://memory.example.test"
    System.put_env("NEX_AGENT_MCP_STREAMABLE_HTTP_SECRET", "super-secret-token")

    config =
      Config.from_map(%{
        "plugins" => %{
          "secrets" => %{
            "workspace:memory" => %{
              "memory_api_token" => %{"env" => "NEX_AGENT_MCP_STREAMABLE_HTTP_SECRET"}
            }
          }
        }
      })

    Application.put_env(:nex_agent, :http_test_req_post, fn url, opts ->
      request = Keyword.fetch!(opts, :json)
      send(parent, {:post, url, request, Keyword.fetch!(opts, :headers)})

      case request_method(request) do
        "initialize" -> json_response(request, %{"capabilities" => %{}})
        "notifications/initialized" -> {:ok, %{status: 202, headers: [], body: ""}}
      end
    end)

    {:ok, pid} =
      MCP.start_link(
        transport: "streamable-http",
        url: "{{plugin.config.endpoint}}/mcp",
        headers: %{
          "Authorization" => "Bearer {{secret.memory_api_token}}",
          "X-Memory-Bank" => "{{plugin.config.bank.template}}"
        },
        plugin_id: "workspace:memory",
        plugin_config: %{
          "endpoint" => endpoint,
          "bank" => %{"template" => "nex-{{workspace.hash}}"}
        },
        config: config,
        workspace: workspace
      )

    refute inspect(transport_state(pid)) =~ "super-secret-token"

    assert :ok = MCP.initialize(pid)

    assert_receive {:post, "https://memory.example.test/mcp", %{method: "initialize"}, headers}
    assert header_value(headers, "authorization") == "Bearer super-secret-token"
    assert header_value(headers, "x-memory-bank") == "nex-#{workspace_hash(workspace)}"

    assert :ok = MCP.stop(pid)
  end

  test "streamable HTTP transport blocks requests with missing header secrets" do
    parent = self()

    Application.put_env(:nex_agent, :http_test_req_post, fn url, _opts ->
      send(parent, {:unexpected_post, url})
      {:ok, %{status: 500, headers: [], body: ""}}
    end)

    {:ok, pid} =
      MCP.start_link(
        transport: "streamable-http",
        url: "https://memory.example.test/mcp",
        headers: %{"Authorization" => "Bearer {{secret.missing}}"}
      )

    assert {:error, error} = MCP.initialize(pid)
    assert error.code == :missing_secret
    assert error.secret_id == "missing"
    refute inspect(error) =~ "Bearer "
    refute_received {:unexpected_post, _url}
    assert :ok = MCP.stop(pid)
  end

  defp json_response(request, result, opts \\ []) do
    {:ok,
     %{
       status: 200,
       headers: Keyword.get(opts, :headers, [{"content-type", "application/json"}]),
       body: %{"jsonrpc" => "2.0", "id" => request_id(request), "result" => result}
     }}
  end

  defp sse_response(request, result) do
    payload =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => request_id(request), "result" => result})

    {:ok,
     %{
       status: 200,
       headers: [{"content-type", "text/event-stream"}],
       body: "event: message\ndata: #{payload}\n\n"
     }}
  end

  defp request_method(%{method: method}), do: method
  defp request_method(%{"method" => method}), do: method

  defp request_id(%{id: id}), do: id
  defp request_id(%{"id" => id}), do: id

  defp header_value(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:nex_agent, key)
  defp restore_env(key, value), do: Application.put_env(:nex_agent, key, value)

  defp transport_state(client_pid) do
    %{transport_pid: transport_pid} = :sys.get_state(client_pid)
    :sys.get_state(transport_pid)
  end

  defp workspace_hash(root) do
    :crypto.hash(:sha256, root)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end
end
