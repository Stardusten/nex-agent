defmodule Nex.Agent.Interface.MCP.Transport.StreamableHTTP do
  @moduledoc """
  Streamable HTTP transport adapter for MCP clients.

  This module owns the HTTP wire contract for the MCP streamable HTTP
  transport. `Nex.Agent.Interface.MCP.Client` owns JSON-RPC method assembly,
  request ids, pending responses, and protocol lifecycle state.
  """

  use GenServer
  alias Nex.Agent.Interface.HTTP

  @behaviour Nex.Agent.Interface.MCP.Transport

  @default_timeout_ms 30_000
  @json_content_type "application/json"
  @sse_content_type "text/event-stream"
  @accept_header @json_content_type <> ", " <> @sse_content_type

  defstruct [
    :owner,
    :url,
    :workspace,
    :protocol_version,
    session_id: nil,
    headers: [],
    timeout_ms: @default_timeout_ms
  ]

  @impl true
  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  @spec send_request(pid(), map()) :: :ok | {:error, term()}
  def send_request(pid, request) do
    GenServer.call(pid, {:send_request, request}, :infinity)
  end

  @impl true
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    with {:ok, owner} <- fetch_owner(opts),
         {:ok, url} <- fetch_url(opts),
         {:ok, headers} <- normalize_headers(get_opt(opts, :headers, [])) do
      {:ok,
       %__MODULE__{
         owner: owner,
         url: url,
         workspace: get_opt(opts, :workspace),
         headers: headers,
         timeout_ms: normalize_timeout(get_opt(opts, :timeout_ms, @default_timeout_ms))
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_request, request}, _from, state) do
    state = maybe_capture_requested_protocol(request, state)

    case post_json_rpc(request, state) do
      {:ok, nil, next_state} ->
        {:reply, :ok, next_state}

      {:ok, response, next_state} ->
        if request_id(request) do
          send(state.owner, {:mcp_transport_response, self(), response})
        end

        {:reply, :ok, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp post_json_rpc(request, state) do
    case HTTP.post(state.url, request_options(request, state)) do
      {:ok, response} ->
        next_state = maybe_store_session_id(response, state)
        parse_response(request, response, next_state)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp request_options(request, state) do
    [
      headers: request_headers(request, state),
      json: request,
      receive_timeout: state.timeout_ms,
      observe_context: %{workspace: state.workspace},
      observe_attrs: %{"interface" => "mcp", "mcp_transport" => "streamable-http"}
    ]
  end

  defp request_headers(request, state) do
    state.headers
    |> put_header("Accept", @accept_header)
    |> put_header("Content-Type", @json_content_type)
    |> maybe_put_protocol_header(request, state)
    |> maybe_put_session_header(state.session_id)
  end

  defp maybe_put_protocol_header(headers, request, %{protocol_version: version})
       when is_binary(version) and version != "" do
    if initialize_request?(request) do
      headers
    else
      put_header(headers, "MCP-Protocol-Version", version)
    end
  end

  defp maybe_put_protocol_header(headers, _request, _state), do: headers

  defp maybe_put_session_header(headers, nil), do: headers
  defp maybe_put_session_header(headers, ""), do: headers

  defp maybe_put_session_header(headers, session_id) do
    put_header(headers, "MCP-Session-Id", session_id)
  end

  defp parse_response(request, response, state) do
    status = response_status(response)

    cond do
      status in [202, 204] and is_nil(request_id(request)) ->
        {:ok, nil, state}

      status in 200..299 ->
        parse_success_response(request, response, state)

      true ->
        {:error, {:http_status, status || :unknown}, state}
    end
  end

  defp parse_success_response(request, response, state) do
    body = response_body(response)

    cond do
      is_nil(request_id(request)) ->
        {:ok, nil, state}

      sse_response?(response, body) ->
        parse_sse_response(body, request_id(request), state)

      true ->
        parse_json_response(body, state)
    end
  end

  defp parse_json_response(%{} = body, state), do: {:ok, body, state}

  defp parse_json_response(body, state) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded, state}
      {:ok, _decoded} -> {:error, :invalid_json_rpc_response, state}
      {:error, reason} -> {:error, {:invalid_json_response, reason}, state}
    end
  end

  defp parse_json_response(_body, state), do: {:error, :empty_http_response, state}

  defp parse_sse_response(body, request_id, state) when is_binary(body) do
    body
    |> sse_data_payloads()
    |> Enum.find_value(fn payload ->
      case Jason.decode(payload) do
        {:ok, %{} = message} ->
          if response_for_request?(message, request_id), do: message

        _ ->
          nil
      end
    end)
    |> case do
      nil -> {:error, :missing_sse_json_rpc_response, state}
      response -> {:ok, response, state}
    end
  end

  defp parse_sse_response(_body, _request_id, state), do: {:error, :empty_sse_response, state}

  defp sse_data_payloads(body) do
    body
    |> String.replace("\r\n", "\n")
    |> String.split("\n\n", trim: true)
    |> Enum.map(&event_data/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp event_data(event) do
    event
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case line do
        "data:" <> data -> [String.trim_leading(data)]
        _other -> []
      end
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp sse_response?(response, body) do
    content_type(response) =~ @sse_content_type or
      (is_binary(body) and
         String.starts_with?(String.trim_leading(body), ["event:", "data:", "id:"]))
  end

  defp response_for_request?(%{"id" => id}, request_id), do: id == request_id
  defp response_for_request?(%{id: id}, request_id), do: id == request_id
  defp response_for_request?(_message, _request_id), do: false

  defp maybe_capture_requested_protocol(%{method: "initialize", params: params}, state) do
    %{state | protocol_version: protocol_version_from_params(params) || state.protocol_version}
  end

  defp maybe_capture_requested_protocol(%{"method" => "initialize", "params" => params}, state) do
    %{state | protocol_version: protocol_version_from_params(params) || state.protocol_version}
  end

  defp maybe_capture_requested_protocol(_request, state), do: state

  defp protocol_version_from_params(params) when is_map(params) do
    case Map.get(params, :protocolVersion) || Map.get(params, "protocolVersion") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp protocol_version_from_params(_params), do: nil

  defp maybe_store_session_id(response, state) do
    case header_value(response_headers(response), "mcp-session-id") do
      value when is_binary(value) and value != "" -> %{state | session_id: value}
      _ -> state
    end
  end

  defp fetch_owner(opts) do
    case get_opt(opts, :owner) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :owner_required}
    end
  end

  defp fetch_url(opts) do
    case get_opt(opts, :url) do
      url when is_binary(url) ->
        url = String.trim(url)
        if url == "", do: {:error, :url_required}, else: {:ok, url}

      _ ->
        {:error, :url_required}
    end
  end

  defp normalize_headers(nil), do: {:ok, []}

  defp normalize_headers(headers) when is_map(headers),
    do: headers |> Map.to_list() |> normalize_headers()

  defp normalize_headers(headers) when is_list(headers) do
    headers =
      headers
      |> Enum.reduce_while([], fn
        {key, value}, acc ->
          normalize_header_pair(key, value, acc)

        [key, value], acc ->
          normalize_header_pair(key, value, acc)

        _other, _acc ->
          {:halt, :error}
      end)

    case headers do
      :error -> {:error, :invalid_headers}
      headers -> {:ok, Enum.reverse(headers)}
    end
  end

  defp normalize_headers(_headers), do: {:error, :invalid_headers}

  defp normalize_header_pair(key, value, acc) do
    with {:ok, key} <- normalize_header_part(key),
         {:ok, value} <- normalize_header_part(value),
         true <- key != "" do
      {:cont, [{key, value} | acc]}
    else
      _ -> {:halt, :error}
    end
  end

  defp normalize_header_part(value)
       when is_binary(value) or is_atom(value) or is_integer(value) or is_float(value) or
              is_boolean(value) do
    {:ok, value |> to_string() |> String.trim()}
  end

  defp normalize_header_part(_value), do: {:error, :invalid_header}

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp normalize_timeout(timeout) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {value, ""} when value > 0 -> value
      _ -> @default_timeout_ms
    end
  end

  defp normalize_timeout(_timeout), do: @default_timeout_ms

  defp put_header(headers, name, value) do
    normalized = String.downcase(name)

    headers
    |> Enum.reject(fn {key, _value} -> String.downcase(to_string(key)) == normalized end)
    |> Kernel.++([{name, value}])
  end

  defp header_value(headers, wanted_name) do
    wanted_name = String.downcase(wanted_name)

    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(to_string(name)) == wanted_name, do: to_string(value)
    end)
  end

  defp response_status(%{status: status}) when is_integer(status), do: status
  defp response_status(%{"status" => status}) when is_integer(status), do: status
  defp response_status(_response), do: nil

  defp response_body(%{body: body}), do: body
  defp response_body(%{"body" => body}), do: body
  defp response_body(_response), do: nil

  defp response_headers(%{headers: headers}), do: normalize_response_headers(headers)
  defp response_headers(%{"headers" => headers}), do: normalize_response_headers(headers)
  defp response_headers(_response), do: []

  defp normalize_response_headers(headers) when is_map(headers), do: Map.to_list(headers)

  defp normalize_response_headers(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {key, value} when is_list(value) ->
        Enum.map(value, &{to_string(key), to_string(&1)})

      {key, value} ->
        [{to_string(key), to_string(value)}]

      _other ->
        []
    end)
  end

  defp normalize_response_headers(_headers), do: []

  defp content_type(response) do
    response_headers(response)
    |> header_value("content-type")
    |> to_string()
    |> String.downcase()
  end

  defp initialize_request?(%{method: "initialize"}), do: true
  defp initialize_request?(%{"method" => "initialize"}), do: true
  defp initialize_request?(_request), do: false

  defp request_id(%{id: id}), do: id
  defp request_id(%{"id" => id}), do: id
  defp request_id(_request), do: nil

  defp get_opt(opts, key, default \\ nil)

  defp get_opt(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp get_opt(opts, key, default) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp get_opt(_opts, _key, default), do: default
end
