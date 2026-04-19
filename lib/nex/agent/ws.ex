defmodule Nex.Agent.WS do
  @moduledoc """
  Shared WebSocket transport for channel clients.

  This module owns connection setup, optional system proxy routing, WebSocket
  upgrade, and frame IO. Channel modules own protocol-specific frame handling.
  """

  use GenServer

  alias Nex.Agent.HTTP

  @connect_timeout_ms 6_000
  @handshake_timeout_ms 5_000

  @type frame :: Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()

  @callback handle_connect(map(), state :: term()) :: {:ok, new_state :: term()}
  @callback handle_frame(frame(), state :: term()) ::
              {:ok, new_state :: term()}
              | {:reply, frame(), new_state :: term()}
              | {:close, new_state :: term()}
  @callback handle_cast(term(), state :: term()) ::
              {:ok, new_state :: term()}
              | {:reply, frame(), new_state :: term()}
              | {:close, new_state :: term()}
  @callback handle_disconnect(map(), state :: term()) :: {:ok, new_state :: term()}
  @callback terminate(term(), state :: term()) :: term()

  @optional_callbacks terminate: 2

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour Nex.Agent.WS

      def handle_connect(_conn, state), do: {:ok, state}

      def handle_cast(message, _state) do
        raise "No handle_cast/2 clause in #{__MODULE__} provided for #{inspect(message)}"
      end

      def handle_disconnect(_status, state), do: {:ok, state}

      defoverridable handle_connect: 2, handle_cast: 2, handle_disconnect: 2
    end
  end

  @spec start_link(String.t(), module(), term(), keyword()) :: GenServer.on_start()
  def start_link(url, callback_module, callback_state, opts \\ [])
      when is_binary(url) and is_atom(callback_module) and is_list(opts) do
    GenServer.start_link(__MODULE__, %{
      url: url,
      callback_module: callback_module,
      callback_state: callback_state,
      extra_headers: Keyword.get(opts, :extra_headers, []),
      connect_fun: Keyword.get(opts, :connect_fun, &connect/2)
    })
  end

  @spec cast(GenServer.server(), term()) :: :ok
  def cast(pid, message), do: GenServer.cast(pid, message)

  @impl true
  def init(state) do
    case state.connect_fun.(state.url, extra_headers: state.extra_headers) do
      {:ok, conn, websocket, request_ref, resp_headers} ->
        case state.callback_module.handle_connect(conn_info(conn, resp_headers), state.callback_state) do
          {:ok, callback_state} ->
            {:ok,
             Map.merge(state, %{
               conn: conn,
               websocket: websocket,
               request_ref: request_ref,
               resp_headers: resp_headers,
               callback_state: callback_state
             })}

          other ->
            _ = Mint.HTTP.close(conn)
            {:stop, {:bad_connect_callback, other}}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast(message, state) do
    case state.callback_module.handle_cast(message, state.callback_state) do
      {:ok, callback_state} ->
        {:noreply, %{state | callback_state: callback_state}}

      {:reply, frame, callback_state} ->
        reply_frame(frame, %{state | callback_state: callback_state})

      {:close, callback_state} ->
        disconnect(:normal, %{state | callback_state: callback_state})

      other ->
        {:stop, {:bad_cast_callback, other}, state}
    end
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        responses
        |> Enum.filter(&websocket_response?(&1, state.request_ref))
        |> handle_responses(%{state | conn: conn})

      {:error, conn, reason, responses} ->
        state = %{state | conn: conn}
        responses = Enum.filter(responses, &websocket_response?(&1, state.request_ref))

        case handle_responses(responses, state) do
          {:noreply, state} -> disconnect({:error, reason}, state)
          {:stop, _reason, _state} = stop -> stop
        end

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    if Map.has_key?(state, :conn) do
      _ = Mint.HTTP.close(state.conn)

      if function_exported?(state.callback_module, :terminate, 2) do
        _ = state.callback_module.terminate(reason, state.callback_state)
      end
    end

    :ok
  end

  @spec connect(String.t(), keyword()) ::
          {:ok, Mint.HTTP.t(), Mint.WebSocket.t(), reference(), Mint.Types.headers()}
          | {:error, term()}
  def connect(url, opts \\ []) when is_binary(url) and is_list(opts) do
    with {:ok, uri} <- parse_uri(url),
         {:ok, conn} <- connect_http(uri, Keyword.get(opts, :connect_http_fun, &Mint.HTTP.connect/4)),
         {:ok, conn, request_ref} <-
           Mint.WebSocket.upgrade(ws_scheme(uri), conn, request_path(uri), Keyword.get(opts, :extra_headers, [])),
         {:ok, conn, responses} <- receive_handshake(conn, request_ref),
         {:ok, conn, websocket} <-
           Mint.WebSocket.new(
             conn,
             request_ref,
             response_status(responses, request_ref),
             response_headers(responses, request_ref)
           ) do
      {:ok, conn, websocket, request_ref, response_headers(responses, request_ref)}
    else
      {:error, _} = error -> error
      {:error, _conn, reason} -> {:error, reason}
      error -> {:error, error}
    end
  end

  defp parse_uri(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        {:ok, %{uri | path: uri.path || "/", port: uri.port || default_port(scheme)}}

      _ ->
        {:error, {:invalid_ws_url, url}}
    end
  end

  defp connect_http(%URI{} = uri, connect_http_fun) do
    scheme = if uri.scheme == "wss", do: :https, else: :http

    opts =
      [
        mode: :active,
        protocols: [:http1],
        transport_opts: [timeout: @connect_timeout_ms]
      ]
      |> maybe_put_proxy(uri)

    connect_http_fun.(scheme, uri.host, uri.port, opts)
  end

  defp maybe_put_proxy(opts, uri) do
    case HTTP.proxy_tuple_for(uri) do
      nil -> opts
      proxy -> Keyword.put(opts, :proxy, proxy)
    end
  end

  defp receive_handshake(conn, request_ref, responses \\ []) do
    if handshake_done?(responses, request_ref) do
      {:ok, conn, responses}
    else
      receive do
        message ->
          case Mint.WebSocket.stream(conn, message) do
            {:ok, conn, new_responses} ->
              receive_handshake(conn, request_ref, responses ++ new_responses)

            {:error, conn, reason, new_responses} ->
              {:error, conn, {:handshake_failed, reason, responses ++ new_responses}}

            :unknown ->
              receive_handshake(conn, request_ref, responses)
          end
      after
        @handshake_timeout_ms ->
          {:error, conn, {:handshake_timeout, responses}}
      end
    end
  end

  defp handshake_done?(responses, request_ref) do
    Enum.any?(responses, &(&1 == {:done, request_ref}))
  end

  defp handle_responses([], state), do: {:noreply, state}

  defp handle_responses([{:data, _request_ref, data} | rest], state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        frames
        |> Enum.reduce_while({:noreply, %{state | websocket: websocket}}, fn
          {:error, reason}, {:noreply, state} ->
            {:halt, disconnect({:error, reason}, state)}

          frame, {:noreply, state} ->
            case handle_frame(frame, state) do
              {:noreply, state} -> {:cont, {:noreply, state}}
              {:stop, _reason, _state} = stop -> {:halt, stop}
            end
        end)
        |> continue_responses(rest)

      {:error, websocket, reason} ->
        disconnect({:error, reason}, %{state | websocket: websocket})
    end
  end

  defp handle_responses([{:done, _request_ref} | _rest], state), do: disconnect({:remote, :closed}, state)
  defp handle_responses([_response | rest], state), do: handle_responses(rest, state)

  defp continue_responses({:noreply, state}, rest), do: handle_responses(rest, state)
  defp continue_responses({:stop, _reason, _state} = stop, _rest), do: stop

  defp handle_frame({:ping, payload}, state), do: reply_frame({:pong, payload}, state)
  defp handle_frame({:close, code, reason}, state), do: disconnect({:remote, code, reason}, state)

  defp handle_frame(frame, state) do
    case state.callback_module.handle_frame(frame, state.callback_state) do
      {:ok, callback_state} ->
        {:noreply, %{state | callback_state: callback_state}}

      {:reply, frame, callback_state} ->
        reply_frame(frame, %{state | callback_state: callback_state})

      {:close, callback_state} ->
        disconnect(:normal, %{state | callback_state: callback_state})

      other ->
        {:stop, {:bad_frame_callback, other}, state}
    end
  end

  defp reply_frame(frame, state) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} -> {:noreply, %{state | websocket: websocket, conn: conn}}
          {:error, conn, reason} -> disconnect({:error, reason}, %{state | websocket: websocket, conn: conn})
        end

      {:error, websocket, reason} ->
        disconnect({:error, reason}, %{state | websocket: websocket})
    end
  end

  defp disconnect(reason, state) do
    _ = state.callback_module.handle_disconnect(%{reason: reason}, state.callback_state)
    {:stop, normalize_stop_reason(reason), state}
  end

  defp normalize_stop_reason(:normal), do: :normal
  defp normalize_stop_reason({:remote, :normal}), do: :normal
  defp normalize_stop_reason({:local, :normal}), do: :normal
  defp normalize_stop_reason({:remote, 1000, _message}), do: :normal
  defp normalize_stop_reason({:local, 1000, _message}), do: :normal
  defp normalize_stop_reason(reason), do: reason

  defp websocket_response?({:data, request_ref, _data}, request_ref), do: true
  defp websocket_response?({:done, request_ref}, request_ref), do: true
  defp websocket_response?(_response, _request_ref), do: false

  defp response_status(responses, request_ref) do
    Enum.find_value(responses, fn
      {:status, ^request_ref, status} -> status
      _ -> nil
    end)
  end

  defp response_headers(responses, request_ref) do
    Enum.find_value(responses, [], fn
      {:headers, ^request_ref, headers} -> headers
      _ -> nil
    end)
  end

  defp conn_info(conn, resp_headers) do
    %{host: conn.host, port: conn.port, resp_headers: resp_headers}
  end

  defp ws_scheme(%URI{scheme: "wss"}), do: :wss
  defp ws_scheme(%URI{scheme: "ws"}), do: :ws

  defp request_path(%URI{path: path, query: nil}), do: path || "/"
  defp request_path(%URI{path: path, query: query}), do: "#{path || "/"}?#{query}"

  defp default_port("ws"), do: 80
  defp default_port("wss"), do: 443
end
