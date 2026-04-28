defmodule Nex.Agent.ControlPlane.Store do
  @moduledoc false

  alias Nex.Agent.ControlPlane.Redactor
  alias Nex.Agent.Workspace

  @levels ~w(debug info warning error critical)
  @kinds ~w(log metric gauge)
  @context_keys ~w(workspace run_id session_key channel chat_id tool_call_id trace_id)

  @type observation :: %{required(String.t()) => term()}

  @spec append(map(), keyword()) :: {:ok, observation()} | {:error, term()}
  def append(observation, opts \\ []) when is_map(observation) do
    normalized = normalize_observation(observation, opts)

    path =
      observations_path(normalized["timestamp"], workspace: normalized["context"]["workspace"])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(normalized) <> "\n", [:append]) do
      {:ok, normalized}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec query(map() | keyword(), keyword()) :: [observation()]
  def query(filters \\ %{}, opts \\ []) do
    filters = normalize_filters(filters)
    limit = normalize_limit(Map.get(filters, "limit"))

    opts
    |> observation_files()
    |> recent_first_observation_files(filters)
    |> collect_recent_matches(filters, limit, [])
  rescue
    _e -> []
  end

  @spec observation_dir(keyword()) :: String.t()
  def observation_dir(opts \\ []) do
    Path.join([workspace_root(opts), "control_plane", "observations"])
  end

  @spec state_dir(keyword()) :: String.t()
  def state_dir(opts \\ []) do
    Path.join([workspace_root(opts), "control_plane", "state"])
  end

  @spec observations_path(DateTime.t() | String.t(), keyword()) :: String.t()
  def observations_path(timestamp_or_date, opts \\ []) do
    date =
      timestamp_or_date
      |> to_string()
      |> String.slice(0, 10)

    Path.join(observation_dir(opts), "#{date}.jsonl")
  end

  @spec gauges_path(keyword()) :: String.t()
  def gauges_path(opts \\ []), do: Path.join(state_dir(opts), "gauges.json")

  @spec budget_path(keyword()) :: String.t()
  def budget_path(opts \\ []), do: Path.join(state_dir(opts), "budget.json")

  @spec normalize_observation(map(), keyword()) :: observation()
  def normalize_observation(observation, opts \\ []) when is_map(observation) do
    observation = stringify_keys(observation)
    context = normalize_context(Map.get(observation, "context", %{}), opts)

    %{
      "id" => present_or(observation["id"], new_id()),
      "timestamp" => present_or(observation["timestamp"], timestamp()),
      "kind" => normalize_enum(observation["kind"], @kinds, "log"),
      "level" => normalize_enum(observation["level"], @levels, "info"),
      "tag" => normalize_tag!(observation["tag"]),
      "source" => normalize_source(observation["source"]),
      "context" => context,
      "attrs" => observation |> Map.get("attrs", %{}) |> normalize_attrs()
    }
    |> Redactor.redact()
  end

  @spec workspace_root(keyword()) :: String.t()
  def workspace_root(opts \\ []) do
    opts
    |> Keyword.get(:workspace)
    |> case do
      nil -> Workspace.root()
      workspace -> workspace
    end
    |> Path.expand()
  end

  @spec stringify_keys(term()) :: term()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value

  defp normalize_attrs(attrs) do
    attrs
    |> stringify_keys()
    |> Map.drop(@context_keys)
  end

  @spec timestamp() :: String.t()
  def timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @spec new_id() :: String.t()
  def new_id do
    "obs_" <> (System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36))
  end

  defp normalize_context(context, opts) do
    context = stringify_keys(context)

    workspace =
      Path.expand(
        Keyword.get(opts, :workspace) || Map.get(context, "workspace") || workspace_root(opts)
      )

    opts_context =
      opts
      |> Enum.flat_map(fn
        {key, value}
        when key in [:run_id, :session_key, :channel, :chat_id, :tool_call_id, :trace_id] ->
          [{Atom.to_string(key), value}]

        _ ->
          []
      end)
      |> Map.new()

    context
    |> Map.merge(opts_context)
    |> Map.put("workspace", workspace)
    |> Map.take(@context_keys)
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp normalize_source(source) when is_map(source) do
    source = stringify_keys(source)

    %{
      "module" => to_string(Map.get(source, "module", "unknown")),
      "function" => normalize_optional_string(Map.get(source, "function")),
      "file" => to_string(Map.get(source, "file", "unknown")),
      "line" => normalize_line(Map.get(source, "line"))
    }
  end

  defp normalize_source(_source) do
    %{"module" => "unknown", "function" => nil, "file" => "unknown", "line" => 1}
  end

  defp normalize_filters(filters) when is_list(filters),
    do: filters |> Map.new() |> normalize_filters()

  defp normalize_filters(filters) when is_map(filters), do: stringify_keys(filters)

  defp normalize_limit(nil), do: 50
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed > 0 -> min(parsed, 500)
      _ -> 50
    end
  end

  defp normalize_limit(_limit), do: 50

  defp observation_files(opts) do
    dir = observation_dir(opts)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _reason} ->
        []
    end
  end

  defp recent_first_observation_files(files, filters) do
    since_date = since_date(filters)

    files
    |> Enum.reverse()
    |> Enum.reject(&older_than_since_date?(&1, since_date))
  end

  defp collect_recent_matches(_files, _filters, limit, acc) when length(acc) >= limit,
    do: Enum.take(acc, limit)

  defp collect_recent_matches([], _filters, _limit, acc), do: acc

  defp collect_recent_matches([path | rest], filters, limit, acc) do
    acc =
      reduce_file_recent_first(path, acc, fn observation, acc ->
        cond do
          length(acc) >= limit ->
            {:halt, acc}

          match_filters?(observation, filters) ->
            {:cont, [observation | acc]}

          true ->
            {:cont, acc}
        end
      end)

    collect_recent_matches(rest, filters, limit, acc)
  end

  defp reduce_file_recent_first(path, acc, fun) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.reduce_while(acc, fn line, acc ->
          case decode_line(line) do
            [observation] -> fun.(observation, acc)
            [] -> {:cont, acc}
          end
        end)

      {:error, _reason} ->
        acc
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = observation} -> [observation]
      _ -> []
    end
  end

  defp older_than_since_date?(_path, nil), do: false

  defp older_than_since_date?(path, since_date) do
    path
    |> Path.basename(".jsonl")
    |> Date.from_iso8601()
    |> case do
      {:ok, file_date} -> Date.compare(file_date, since_date) == :lt
      {:error, _reason} -> false
    end
  end

  defp since_date(%{"since" => value}) do
    if blank?(value) do
      nil
    else
      case DateTime.from_iso8601(to_string(value)) do
        {:ok, datetime, _offset} -> DateTime.to_date(datetime)
        {:error, _reason} -> nil
      end
    end
  end

  defp since_date(_filters), do: nil

  defp match_filters?(observation, filters) do
    Enum.all?(filters, fn
      {"limit", _value} ->
        true

      {"id", value} ->
        id_matches?(observation, value)

      {"tag", value} ->
        blank?(value) or observation["tag"] == value

      {"tag_prefix", value} ->
        blank?(value) or String.starts_with?(to_string(observation["tag"]), to_string(value))

      {"kind", value} ->
        blank?(value) or observation["kind"] == value

      {"level", value} ->
        blank?(value) or observation["level"] == value

      {"run_id", value} ->
        blank?(value) or get_in(observation, ["context", "run_id"]) == value

      {"session_key", value} ->
        blank?(value) or get_in(observation, ["context", "session_key"]) == value

      {"channel", value} ->
        blank?(value) or get_in(observation, ["context", "channel"]) == value

      {"chat_id", value} ->
        blank?(value) or get_in(observation, ["context", "chat_id"]) == value

      {"tool_call_id", value} ->
        blank?(value) or get_in(observation, ["context", "tool_call_id"]) == value

      {"tool_name", value} ->
        blank?(value) or get_in(observation, ["attrs", "tool_name"]) == value

      {"tool", value} ->
        blank?(value) or tool_matches?(observation, value)

      {"trace_id", value} ->
        blank?(value) or get_in(observation, ["context", "trace_id"]) == value

      {"since", value} ->
        blank?(value) or after_since?(observation["timestamp"], value)

      {"query", value} ->
        blank?(value) or contains_query?(observation, value)

      {_key, _value} ->
        true
    end)
  end

  defp after_since?(timestamp, since) do
    with {:ok, observed, _} <- DateTime.from_iso8601(to_string(timestamp)),
         {:ok, boundary, _} <- DateTime.from_iso8601(to_string(since)) do
      DateTime.compare(observed, boundary) in [:gt, :eq]
    else
      _ -> true
    end
  end

  defp contains_query?(observation, query) do
    haystack =
      observation
      |> Jason.encode!()
      |> String.downcase()

    String.contains?(haystack, query |> to_string() |> String.downcase())
  end

  defp tool_matches?(observation, value) do
    value = to_string(value)

    get_in(observation, ["context", "tool_call_id"]) == value or
      get_in(observation, ["attrs", "tool_name"]) == value
  end

  defp id_matches?(_observation, []), do: false

  defp id_matches?(observation, values) when is_list(values) do
    values = Enum.reject(values, &blank?/1)
    Enum.any?(values, &id_matches?(observation, &1))
  end

  defp id_matches?(observation, value) do
    blank?(value) or observation["id"] == to_string(value)
  end

  defp normalize_tag!(tag) when is_binary(tag) do
    tag = String.trim(tag)
    if tag == "", do: raise(ArgumentError, "tag is required"), else: tag
  end

  defp normalize_tag!(_tag), do: raise(ArgumentError, "tag must be a string")

  defp normalize_enum(value, allowed, default) when is_binary(value) do
    if value in allowed, do: value, else: default
  end

  defp normalize_enum(_value, _allowed, default), do: default

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp normalize_line(line) when is_integer(line) and line > 0, do: line
  defp normalize_line(_line), do: 1

  defp present_or(nil, fallback), do: fallback
  defp present_or("", fallback), do: fallback
  defp present_or(value, _fallback), do: value

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
