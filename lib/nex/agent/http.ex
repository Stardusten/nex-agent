defmodule Nex.Agent.HTTP do
  @moduledoc false

  @spec maybe_add_proxy(Keyword.t(), String.t() | URI.t()) :: Keyword.t()
  def maybe_add_proxy(opts, url_or_uri) do
    case proxy_tuple_for(url_or_uri) do
      nil ->
        opts

      proxy ->
        Keyword.update(opts, :connect_options, [proxy: proxy], &Keyword.put(&1, :proxy, proxy))
    end
  end

  defp proxy_tuple_for(url) when is_binary(url), do: url |> URI.parse() |> proxy_tuple_for()

  defp proxy_tuple_for(%URI{scheme: scheme, host: host} = uri)
       when scheme in ["http", "https"] and is_binary(host) and host != "" do
    if no_proxy_uri?(uri) do
      nil
    else
      scheme
      |> proxy_url_for_scheme()
      |> parse_proxy_tuple()
    end
  end

  defp proxy_tuple_for(_), do: nil

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
