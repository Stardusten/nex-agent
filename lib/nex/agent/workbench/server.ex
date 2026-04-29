defmodule Nex.Agent.Workbench.Server do
  @moduledoc false

  use GenServer
  require Logger

  alias Nex.Agent.Runtime
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Workbench.Router

  defstruct [
    :listener,
    :bound_host,
    :bound_port,
    :runtime_provider,
    :last_error,
    enabled?: false
  ]

  @recv_timeout 5_000
  @max_header_bytes 16_384
  @max_body_bytes 1_048_576

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec status(pid() | atom()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe?, true), do: subscribe_runtime()

    state = %__MODULE__{
      runtime_provider: Keyword.get(opts, :runtime_provider, &Runtime.current/0)
    }

    {:ok, configure(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled: state.enabled?,
       host: state.bound_host,
       port: state.bound_port,
       running: is_port(state.listener),
       last_error: state.last_error
     }, state}
  end

  @impl true
  def handle_info({:runtime_updated, _payload}, state), do: {:noreply, configure(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_listener(state)
    :ok
  end

  defp configure(state) do
    case current_snapshot(state) do
      {:ok, %Snapshot{} = snapshot} ->
        workbench = snapshot.workbench || %{}
        runtime = Map.get(workbench, :runtime, %{})

        if runtime["enabled"] == true do
          ensure_listener(state, runtime)
        else
          state
          |> close_listener()
          |> then(&%{&1 | enabled?: false, bound_host: nil, bound_port: nil, last_error: nil})
        end

      {:error, reason} ->
        %{state | last_error: inspect(reason)}
    end
  end

  defp ensure_listener(state, %{"host" => "127.0.0.1", "port" => port} = _runtime)
       when is_integer(port) and port >= 0 and port <= 65_535 do
    if state.listener && state.bound_host == "127.0.0.1" && requested_port_matches?(state, port) do
      %{state | enabled?: true, last_error: nil}
    else
      state = close_listener(state)

      case :gen_tcp.listen(port, [
             :binary,
             {:packet, :raw},
             {:active, false},
             {:reuseaddr, true},
             {:ip, {127, 0, 0, 1}}
           ]) do
        {:ok, listener} ->
          {:ok, {_ip, bound_port}} = :inet.sockname(listener)
          {:ok, _pid} = Task.start(fn -> accept_loop(listener, state.runtime_provider) end)

          Logger.info("[Workbench.Server] Listening on 127.0.0.1:#{bound_port}")

          %{
            state
            | listener: listener,
              bound_host: "127.0.0.1",
              bound_port: bound_port,
              enabled?: true,
              last_error: nil
          }

        {:error, reason} ->
          Logger.warning("[Workbench.Server] Listen failed: #{inspect(reason)}")

          %{
            state
            | listener: nil,
              bound_host: nil,
              bound_port: nil,
              enabled?: true,
              last_error: inspect(reason)
          }
      end
    end
  end

  defp ensure_listener(state, runtime) do
    close_listener(state)

    %{
      state
      | enabled?: true,
        bound_host: nil,
        bound_port: nil,
        last_error: "invalid workbench runtime: #{inspect(runtime)}"
    }
  end

  defp requested_port_matches?(state, 0), do: is_integer(state.bound_port)
  defp requested_port_matches?(state, port), do: state.bound_port == port

  defp close_listener(%__MODULE__{listener: listener} = state) when is_port(listener) do
    _ = :gen_tcp.close(listener)
    %{state | listener: nil}
  end

  defp close_listener(state), do: state

  defp subscribe_runtime do
    case Runtime.subscribe() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Workbench.Server] Runtime subscribe failed: #{inspect(reason)}")
    end
  end

  defp current_snapshot(%__MODULE__{runtime_provider: provider}) do
    case provider.() do
      {:ok, %Snapshot{} = snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
      %Snapshot{} = snapshot -> {:ok, snapshot}
      other -> {:error, {:invalid_runtime_provider_result, other}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp accept_loop(listener, runtime_provider) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, _pid} = Task.start(fn -> handle_socket(socket, runtime_provider) end)
        accept_loop(listener, runtime_provider)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_socket(socket, runtime_provider) do
    response =
      case read_request(socket) do
        {:ok, request} ->
          case normalize_provider_result(runtime_provider.()) do
            {:ok, %Snapshot{} = snapshot} ->
              Router.dispatch(request.method, request.target, request.body, snapshot)

            {:error, reason} ->
              {500, %{"error" => "runtime unavailable: #{format_error(reason)}"}}
          end

        {:error, reason} ->
          request_error_response(reason)
      end

    send_response(socket, response)
    :gen_tcp.close(socket)
  rescue
    e ->
      send_response(socket, {500, %{"error" => format_error(Exception.message(e))}})
      :gen_tcp.close(socket)
  end

  defp normalize_provider_result({:ok, %Snapshot{} = snapshot}), do: {:ok, snapshot}
  defp normalize_provider_result(%Snapshot{} = snapshot), do: {:ok, snapshot}
  defp normalize_provider_result({:error, reason}), do: {:error, reason}
  defp normalize_provider_result(other), do: {:error, inspect(other)}

  defp read_request(socket) do
    with {:ok, data} <- recv_until_headers(socket, ""),
         {:ok, head, rest} <- split_head(data),
         {:ok, method, target, headers} <- parse_head(head),
         {:ok, length} <- content_length(headers),
         {:ok, body} <- read_body(socket, rest, length) do
      {:ok, %{method: method, target: target, body: body}}
    end
  end

  defp recv_until_headers(socket, acc) do
    cond do
      String.contains?(acc, "\r\n\r\n") ->
        {:ok, acc}

      byte_size(acc) > @max_header_bytes ->
        {:error, {:http, 431, "request headers too large"}}

      true ->
        case :gen_tcp.recv(socket, 0, @recv_timeout) do
          {:ok, chunk} -> recv_until_headers(socket, acc <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp split_head(data) do
    case String.split(data, "\r\n\r\n", parts: 2) do
      [head, rest] -> {:ok, head, rest}
      _ -> {:error, :bad_request}
    end
  end

  defp parse_head(head) do
    [request_line | header_lines] = String.split(head, "\r\n")

    with [method, target, _version] <- String.split(request_line, " ", parts: 3) do
      headers =
        header_lines
        |> Enum.flat_map(fn line ->
          case String.split(line, ":", parts: 2) do
            [key, value] -> [{String.downcase(String.trim(key)), String.trim(value)}]
            _ -> []
          end
        end)
        |> Map.new()

      {:ok, method, target, headers}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp content_length(headers) do
    case Integer.parse(Map.get(headers, "content-length", "0")) do
      {length, ""} when length >= 0 and length <= @max_body_bytes ->
        {:ok, length}

      {length, ""} when length > @max_body_bytes ->
        {:error, {:http, 413, "request body too large"}}

      _ ->
        {:error, {:http, 400, "invalid content-length"}}
    end
  end

  defp read_body(_socket, _rest, 0), do: {:ok, ""}

  defp read_body(_socket, rest, length) when byte_size(rest) >= length do
    {:ok, binary_part(rest, 0, length)}
  end

  defp read_body(socket, rest, length) do
    case :gen_tcp.recv(socket, length - byte_size(rest), @recv_timeout) do
      {:ok, chunk} -> read_body(socket, rest <> chunk, length)
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_error_response({:http, status, reason}), do: {status, %{"error" => reason}}
  defp request_error_response(:timeout), do: {408, %{"error" => "request timed out"}}
  defp request_error_response(:bad_request), do: {400, %{"error" => "bad request"}}
  defp request_error_response(reason), do: {400, %{"error" => format_error(reason)}}

  defp format_error(reason) when is_binary(reason), do: truncate(reason, 500)
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason, limit: 20, printable_limit: 120)

  defp truncate(value, limit) do
    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "...[truncated]"
    else
      value
    end
  end

  defp send_response(socket, {204, _payload}) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 204 No Content\r\n",
      common_headers(),
      cors_headers(),
      "Content-Length: 0\r\n\r\n"
    ])
  end

  defp send_response(socket, {:html, status, body}) when is_binary(body) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{reason(status)}\r\n",
      "Content-Type: text/html; charset=utf-8\r\n",
      common_headers(),
      "Content-Length: #{byte_size(body)}\r\n",
      "\r\n",
      body
    ])
  end

  defp send_response(socket, {:asset, status, content_type, body}) when is_binary(body) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{reason(status)}\r\n",
      "Content-Type: #{content_type}\r\n",
      common_headers(),
      app_asset_cors_headers(),
      "Content-Length: #{byte_size(body)}\r\n",
      "\r\n",
      body
    ])
  end

  defp send_response(socket, {status, payload}) do
    body = Jason.encode!(payload)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{reason(status)}\r\n",
      "Content-Type: application/json; charset=utf-8\r\n",
      common_headers(),
      cors_headers(),
      "Content-Length: #{byte_size(body)}\r\n",
      "\r\n",
      body
    ])
  end

  defp common_headers do
    [
      "Cache-Control: no-store\r\n",
      "Connection: close\r\n",
      "Referrer-Policy: no-referrer\r\n",
      "X-Content-Type-Options: nosniff\r\n"
    ]
  end

  defp cors_headers do
    [
      "Access-Control-Allow-Origin: http://127.0.0.1\r\n",
      "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n",
      "Access-Control-Allow-Headers: content-type\r\n"
    ]
  end

  defp app_asset_cors_headers do
    [
      "Access-Control-Allow-Origin: *\r\n",
      "Access-Control-Allow-Methods: GET, OPTIONS\r\n",
      "Cross-Origin-Resource-Policy: cross-origin\r\n"
    ]
  end

  defp reason(200), do: "OK"
  defp reason(400), do: "Bad Request"
  defp reason(404), do: "Not Found"
  defp reason(408), do: "Request Timeout"
  defp reason(413), do: "Payload Too Large"
  defp reason(431), do: "Request Header Fields Too Large"
  defp reason(500), do: "Internal Server Error"
  defp reason(_), do: "OK"
end
