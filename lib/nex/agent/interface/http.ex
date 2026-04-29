defmodule Nex.Agent.Interface.HTTP do
  @moduledoc false

  alias Nex.Agent.Observe.ControlPlane.Log, as: ControlPlaneLog
  alias Nex.Agent.Conversation.RunControl
  require ControlPlaneLog

  @type proxy_tuple :: {:http | :https, String.t(), :inet.port_number(), keyword()}
  @type req_method :: :get | :post | :put | :patch | :delete

  @default_req_opts [retry: false, receive_timeout: 30_000, finch: Req.Finch]
  @internal_opts [:cancel_ref, :observe_context, :observe_attrs]
  @cancel_poll_ms 50

  @spec request(req_method(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(method, url, opts \\ []) when method in [:get, :post, :put, :patch, :delete] do
    {internal_opts, opts} = Keyword.split(opts, @internal_opts)

    opts =
      @default_req_opts
      |> Keyword.merge(opts)
      |> maybe_add_proxy(url)
      |> normalize_req_transport_opts()

    run_request(method, request_fun(method), url, opts, internal_opts)
  end

  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get(url, opts \\ []), do: request(:get, url, opts)

  @spec post(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def post(url, opts \\ []), do: request(:post, url, opts)

  @spec put(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def put(url, opts \\ []), do: request(:put, url, opts)

  @spec patch(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def patch(url, opts \\ []), do: request(:patch, url, opts)

  @spec delete(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def delete(url, opts \\ []), do: request(:delete, url, opts)

  defp normalize_req_transport_opts(opts) do
    if Keyword.has_key?(opts, :connect_options) do
      Keyword.delete(opts, :finch)
    else
      opts
    end
  end

  defp request_fun(method) do
    Application.get_env(:nex_agent, :"http_test_req_#{method}") ||
      case method do
        :get -> &Req.get/2
        :post -> &Req.post/2
        :put -> &Req.put/2
        :patch -> &Req.patch/2
        :delete -> &Req.delete/2
      end
  end

  defp run_request(method, request_fun, url, opts, internal_opts) do
    timeout = Keyword.get(opts, :receive_timeout, 30_000)
    cancel_ref = Keyword.get(internal_opts, :cancel_ref)
    observe_opts = observe_opts(internal_opts)
    started_at = System.monotonic_time(:millisecond)
    base_attrs = http_attrs(method, url, internal_opts)
    emit_observation(:info, "http.request.started", base_attrs, observe_opts)

    task =
      Task.async(fn ->
        try do
          request_fun.(url, opts)
        rescue
          e ->
            {:error, {:exception, exception_class(e), Exception.message(e)}}
        catch
          kind, reason ->
            {:error, {:exception, to_string(kind), inspect(reason)}}
        end
      end)

    result = wait_request(task, timeout, cancel_ref, started_at)
    duration_ms = duration_since(started_at)
    emit_request_result(result, base_attrs, duration_ms, observe_opts)
    result
  end

  defp wait_request(task, timeout_ms, cancel_ref, started_at_ms) do
    cond do
      cancelled?(cancel_ref) ->
        Task.shutdown(task, :brutal_kill)
        {:error, :cancelled}

      System.monotonic_time(:millisecond) - started_at_ms >= timeout_ms ->
        case Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {:error, :timeout}
        end

      true ->
        case Task.yield(task, @cancel_poll_ms) do
          {:ok, result} ->
            result

          {:exit, reason} ->
            {:error, {:exception, "exit", inspect(reason)}}

          nil ->
            wait_request(task, timeout_ms, cancel_ref, started_at_ms)
        end
    end
  end

  defp cancelled?(ref) when is_reference(ref), do: RunControl.cancelled?(ref)
  defp cancelled?(_ref), do: false

  defp emit_request_result({:ok, response} = _result, attrs, duration_ms, opts) do
    attrs =
      attrs
      |> Map.put("duration_ms", duration_ms)
      |> maybe_put_attr("status", response_status(response))

    emit_observation(:info, "http.request.finished", attrs, opts)
  end

  defp emit_request_result({:error, :timeout}, attrs, duration_ms, opts) do
    attrs =
      attrs
      |> Map.put("duration_ms", duration_ms)
      |> Map.put("reason_type", "timeout")
      |> Map.put("retryable", true)

    emit_observation(:error, "http.request.timeout", attrs, opts)
  end

  defp emit_request_result({:error, :cancelled}, attrs, duration_ms, opts) do
    attrs =
      attrs
      |> Map.put("duration_ms", duration_ms)
      |> Map.put("reason_type", "cancelled")
      |> Map.put("retryable", false)
      |> Map.put("cancelled", true)

    emit_observation(:warning, "http.request.cancelled", attrs, opts)
  end

  defp emit_request_result({:error, {:exception, class, _message}}, attrs, duration_ms, opts) do
    attrs =
      attrs
      |> Map.put("duration_ms", duration_ms)
      |> Map.put("reason_type", class)
      |> Map.put("retryable", false)

    emit_observation(:error, "http.request.failed", attrs, opts)
  end

  defp emit_request_result({:error, reason}, attrs, duration_ms, opts) do
    attrs =
      attrs
      |> Map.put("duration_ms", duration_ms)
      |> Map.put("reason_type", reason_type(reason))
      |> Map.put("retryable", retryable_reason?(reason))

    emit_observation(:error, "http.request.failed", attrs, opts)
  end

  defp emit_request_result(_other, attrs, duration_ms, opts) do
    attrs =
      attrs
      |> Map.put("duration_ms", duration_ms)
      |> Map.put("reason_type", "unexpected_result")
      |> Map.put("retryable", false)

    emit_observation(:error, "http.request.failed", attrs, opts)
  end

  defp observe_opts(internal_opts) do
    context = Keyword.get(internal_opts, :observe_context, %{})

    []
    |> maybe_put_opt(:workspace, Map.get(context, :workspace) || Map.get(context, "workspace"))
    |> maybe_put_opt(:run_id, Map.get(context, :run_id) || Map.get(context, "run_id"))
    |> maybe_put_opt(
      :session_key,
      Map.get(context, :session_key) || Map.get(context, "session_key")
    )
    |> maybe_put_opt(:channel, Map.get(context, :channel) || Map.get(context, "channel"))
    |> maybe_put_opt(:chat_id, Map.get(context, :chat_id) || Map.get(context, "chat_id"))
    |> maybe_put_opt(
      :tool_call_id,
      Map.get(context, :tool_call_id) || Map.get(context, "tool_call_id")
    )
    |> maybe_put_opt(:trace_id, Map.get(context, :trace_id) || Map.get(context, "trace_id"))
  end

  defp http_attrs(method, url, internal_opts) do
    uri = URI.parse(url)

    %{
      "method" => Atom.to_string(method),
      "scheme" => uri.scheme,
      "host" => uri.host,
      "path" => uri.path || "/"
    }
    |> Map.merge(Keyword.get(internal_opts, :observe_attrs, %{}) |> stringify_keys())
    |> Map.take(~w(method scheme host path status duration_ms reason_type retryable cancelled))
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp emit_observation(level, tag, attrs, opts) do
    case level do
      :info -> ControlPlaneLog.info(tag, attrs, opts)
      :warning -> ControlPlaneLog.warning(tag, attrs, opts)
      :error -> ControlPlaneLog.error(tag, attrs, opts)
    end

    :ok
  rescue
    _e -> :ok
  end

  defp response_status(%{status: status}) when is_integer(status), do: status
  defp response_status(%{"status" => status}) when is_integer(status), do: status
  defp response_status(_response), do: nil

  defp reason_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_type({type, _detail}) when is_atom(type), do: Atom.to_string(type)
  defp reason_type(%{__struct__: struct}), do: struct |> Module.split() |> List.last()
  defp reason_type(reason) when is_binary(reason), do: String.slice(reason, 0, 120)
  defp reason_type(_reason), do: "error"

  defp retryable_reason?(reason) when reason in [:timeout, :closed, :econnreset], do: true
  defp retryable_reason?(_reason), do: false

  defp exception_class(%{__struct__: struct}), do: inspect(struct)
  defp exception_class(_), do: "Exception"

  defp duration_since(started_at), do: System.monotonic_time(:millisecond) - started_at

  defp maybe_put_attr(map, _key, nil), do: map
  defp maybe_put_attr(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_), do: %{}

  @spec maybe_add_proxy(Keyword.t(), String.t() | URI.t()) :: Keyword.t()
  def maybe_add_proxy(opts, url_or_uri) do
    case proxy_tuple_for(url_or_uri) do
      nil ->
        opts

      proxy ->
        Keyword.update(opts, :connect_options, [proxy: proxy], &Keyword.put(&1, :proxy, proxy))
    end
  end

  @spec proxy_tuple_for(String.t() | URI.t()) :: proxy_tuple() | nil
  def proxy_tuple_for(url) when is_binary(url), do: url |> URI.parse() |> proxy_tuple_for()

  def proxy_tuple_for(%URI{scheme: scheme, host: host} = uri)
      when scheme in ["http", "https", "ws", "wss"] and is_binary(host) and host != "" do
    if no_proxy_uri?(uri) do
      nil
    else
      scheme
      |> proxy_scheme()
      |> proxy_url_for_scheme()
      |> parse_proxy_tuple()
    end
  end

  def proxy_tuple_for(_), do: nil

  defp proxy_scheme("wss"), do: "https"
  defp proxy_scheme("ws"), do: "http"
  defp proxy_scheme(scheme), do: scheme

  defp proxy_url_for_scheme("https") do
    first_present_env([
      "HTTPS_PROXY",
      "https_proxy",
      "ALL_PROXY",
      "all_proxy",
      "HTTP_PROXY",
      "http_proxy"
    ])
  end

  defp proxy_url_for_scheme("http") do
    first_present_env(["HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"])
  end

  defp first_present_env(keys) do
    Enum.find_value(keys, fn key ->
      case System.get_env(key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp parse_proxy_tuple(nil), do: nil

  defp parse_proxy_tuple(proxy_url) do
    case URI.parse(proxy_url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) and host != "" ->
        proxy_scheme = if String.downcase(scheme || "") == "https", do: :https, else: :http
        proxy_port = if is_integer(port) and port > 0, do: port, else: default_port(proxy_scheme)
        {proxy_scheme, host, proxy_port, []}

      _ ->
        nil
    end
  end

  defp default_port(:https), do: 443
  defp default_port(:http), do: 80

  defp no_proxy_uri?(%URI{scheme: scheme, host: host, port: port}) do
    host = normalize_host(host)
    request_port = port || default_port_for_scheme(scheme)

    "NO_PROXY"
    |> System.get_env()
    |> case do
      nil -> System.get_env("no_proxy")
      value -> value
    end
    |> no_proxy_entries()
    |> Enum.any?(&uri_matches_no_proxy?(host, request_port, &1))
  end

  defp no_proxy_entries(nil), do: []

  defp no_proxy_entries(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  defp uri_matches_no_proxy?(_host, _port, "*"), do: true

  defp uri_matches_no_proxy?(host, port, entry) do
    case parse_no_proxy_entry(entry) do
      %{host: entry_host, port: entry_port} when entry_host != "" ->
        host_matches_no_proxy?(host, entry_host) and (is_nil(entry_port) or entry_port == port)

      _ ->
        false
    end
  end

  defp host_matches_no_proxy?(host, entry_host) do
    host == entry_host or String.ends_with?(host, "." <> entry_host)
  end

  defp parse_no_proxy_entry(entry) do
    case entry do
      <<"[", _::binary>> -> parse_ipv6_no_proxy_entry(entry)
      _ -> parse_host_no_proxy_entry(entry)
    end
  end

  defp parse_ipv6_no_proxy_entry(entry) do
    case Regex.named_captures(~r/^\[(?<host>[^\]]+)\](?::(?<port>\d+))?$/, entry) do
      %{"host" => host} = captures ->
        %{host: normalize_host(host), port: parse_port(Map.get(captures, "port"))}

      _ ->
        nil
    end
  end

  defp parse_host_no_proxy_entry(entry) do
    case String.split(entry, ":", parts: 2) do
      [host, port] when port != "" ->
        %{host: normalize_entry_host(host), port: parse_port(port)}

      [host, ""] ->
        %{host: normalize_entry_host(host), port: nil}

      [host] ->
        %{host: normalize_entry_host(host), port: nil}
    end
  end

  defp parse_port(nil), do: nil
  defp parse_port(""), do: nil

  defp parse_port(value) do
    case Integer.parse(value) do
      {port, ""} when port > 0 -> port
      _ -> nil
    end
  end

  defp normalize_entry_host(host) do
    host
    |> String.trim_leading("*.")
    |> String.trim_leading(".")
    |> normalize_host()
  end

  defp normalize_host(host) do
    host
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.downcase()
  end

  defp default_port_for_scheme("https"), do: 443
  defp default_port_for_scheme("http"), do: 80
end
