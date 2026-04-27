defmodule Nex.Agent.Hooks do
  @moduledoc false

  alias Nex.Agent.ControlPlane.Log
  alias Nex.Agent.Workspace
  require Log

  @registry_relative Path.join("hooks", "hooks.json")
  @default_max_chars 12_000
  @default_total_max_chars 30_000
  @allowed_events ["prompt.build.before"]
  @allowed_kinds ["file", "text"]
  @allowed_on_error ["warn", "skip", "block"]
  @blocked_paths [
    "~/.zshrc",
    "~/.nex/agent/config.json"
  ]

  @spec registry_path(keyword()) :: String.t()
  def registry_path(opts \\ []) do
    opts
    |> workspace()
    |> Path.join(@registry_relative)
    |> Path.expand()
  end

  @spec default_registry_doc() :: map()
  def default_registry_doc, do: %{"version" => 1, "hooks" => []}

  @spec load(keyword()) :: map()
  def load(opts \\ []) do
    path = registry_path(opts)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, doc} when is_map(doc) ->
            compile_doc(doc, path)

          {:ok, _other} ->
            build_data(
              [],
              [diagnostic(:invalid_registry, path, "hooks registry must be an object")],
              path
            )

          {:error, reason} ->
            build_data([], [diagnostic(:invalid_json, path, Exception.message(reason))], path)
        end

      {:error, :enoent} ->
        build_data([], [], path)

      {:error, reason} ->
        build_data([], [diagnostic(:read_failed, path, inspect(reason))], path)
    end
  end

  @spec read_registry_doc(keyword()) :: {:ok, map()} | {:error, String.t()}
  def read_registry_doc(opts \\ []) do
    path = registry_path(opts)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, doc} when is_map(doc) -> {:ok, normalize_registry_doc(doc)}
          {:ok, _other} -> {:error, "hooks registry must be an object"}
          {:error, reason} -> {:error, "invalid hooks JSON: #{Exception.message(reason)}"}
        end

      {:error, :enoent} ->
        {:ok, default_registry_doc()}

      {:error, reason} ->
        {:error, "could not read hooks registry: #{inspect(reason)}"}
    end
  end

  @spec write_registry_doc(map(), keyword()) :: :ok | {:error, String.t()}
  def write_registry_doc(doc, opts \\ []) when is_map(doc) do
    path = registry_path(opts)
    dir = Path.dirname(path)
    tmp = Path.join(dir, ".hooks.json.tmp-#{System.unique_integer([:positive])}")

    with :ok <- mkdir_p(dir),
         {:ok, json} <- encode_doc(normalize_registry_doc(doc)),
         :ok <- File.write(tmp, json <> "\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, "could not write hooks registry: #{inspect(reason)}"}
    end
  end

  @spec run(atom() | String.t(), map() | nil, map()) :: {:ok, [map()]} | {:error, String.t()}
  def run(event, hooks_data, ctx) when is_map(ctx) do
    event = normalize_event(event)
    ctx = normalize_context(ctx)
    entries = hooks_entries(hooks_data)

    entries
    |> Enum.filter(&entry_matches?(&1, event, ctx))
    |> Enum.sort_by(&{entry_priority(&1), Map.get(&1, "id", "")})
    |> build_fragments(ctx, @default_total_max_chars)
  end

  defp compile_doc(doc, path) do
    version = Map.get(doc, "version", 1)
    raw_hooks = Map.get(doc, "hooks", [])

    if is_list(raw_hooks) do
      {entries, diagnostics} =
        raw_hooks
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {entry, index}, {entries, diagnostics} ->
          case compile_entry(entry, index) do
            {:ok, compiled} -> {[compiled | entries], diagnostics}
            {:error, diag} -> {entries, [Map.put(diag, "index", index) | diagnostics]}
          end
        end)

      build_data(Enum.reverse(entries), Enum.reverse(diagnostics), path, version)
    else
      build_data([], [diagnostic(:invalid_hooks, path, "hooks must be a list")], path, version)
    end
  end

  defp compile_entry(entry, _index) when is_map(entry) do
    entry = stringify_keys(entry)
    advice = stringify_keys(Map.get(entry, "advice", %{}))
    pointcut = stringify_keys(Map.get(entry, "pointcut", %{}))

    with {:ok, id} <- required_string(entry, "id"),
         {:ok, event} <- allowed_string(entry, "event", @allowed_events, "prompt.build.before"),
         {:ok, kind} <- allowed_string(advice, "kind", @allowed_kinds, nil),
         {:ok, on_error} <- allowed_string(advice, "on_error", @allowed_on_error, "warn") do
      compiled_advice =
        advice
        |> Map.put("kind", kind)
        |> Map.put("title", normalize_string(Map.get(advice, "title")) || id)
        |> Map.put("priority", normalize_integer(Map.get(advice, "priority"), 100))
        |> Map.put(
          "max_chars",
          normalize_integer(Map.get(advice, "max_chars"), @default_max_chars)
        )
        |> Map.put("on_error", on_error)

      {:ok,
       %{
         "id" => id,
         "enabled" => Map.get(entry, "enabled", true) == true,
         "event" => event,
         "pointcut" => pointcut,
         "advice" => compiled_advice
       }}
    else
      {:error, reason} -> {:error, diagnostic(:invalid_entry, nil, reason)}
    end
  end

  defp compile_entry(_entry, _index),
    do: {:error, diagnostic(:invalid_entry, nil, "hook entry must be an object")}

  defp build_data(entries, diagnostics, path, version \\ 1) do
    %{
      entries: entries,
      diagnostics: diagnostics,
      path: path,
      version: version,
      hash: hash({entries, diagnostics, version})
    }
  end

  defp build_fragments(entries, ctx, total_budget) do
    entries
    |> Enum.reduce_while({[], total_budget}, fn entry, {fragments, remaining} ->
      if remaining <= 0 do
        emit_skipped(entry, ctx, "total hook budget exhausted")
        {:cont, {fragments, remaining}}
      else
        case build_fragment(entry, ctx, remaining) do
          {:ok, nil} ->
            {:cont, {fragments, remaining}}

          {:ok, fragment} ->
            used = Map.get(fragment, "chars", 0)
            emit_injected(entry, fragment, ctx)
            {:cont, {[fragment | fragments], max(remaining - used, 0)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {fragments, _remaining} -> {:ok, Enum.reverse(fragments)}
    end
  end

  defp build_fragment(%{"advice" => %{"kind" => "text"} = advice} = entry, ctx, remaining) do
    case literal_content(Map.get(advice, "content")) do
      nil ->
        handle_advice_error(entry, ctx, "text hook requires advice.content")

      content ->
        {:ok, fragment_from_content(entry, "text", "inline", content, remaining)}
    end
  end

  defp build_fragment(%{"advice" => %{"kind" => "file"} = advice} = entry, ctx, remaining) do
    case normalize_string(Map.get(advice, "path")) do
      nil ->
        handle_advice_error(entry, ctx, "file hook requires advice.path")

      path ->
        read_file_fragment(entry, ctx, path, remaining)
    end
  end

  defp build_fragment(entry, ctx, _remaining),
    do: handle_advice_error(entry, ctx, "unsupported hook advice")

  defp read_file_fragment(entry, ctx, path, remaining) do
    expanded = Path.expand(path)

    cond do
      blocked_path?(expanded) ->
        handle_advice_error(entry, ctx, "hook file path is blocked: #{expanded}")

      not File.regular?(expanded) ->
        handle_advice_error(entry, ctx, "hook file must be a regular file: #{expanded}")

      true ->
        case File.read(expanded) do
          {:ok, content} ->
            {:ok, fragment_from_content(entry, "file", expanded, content, remaining)}

          {:error, reason} ->
            handle_advice_error(
              entry,
              ctx,
              "could not read hook file #{expanded}: #{inspect(reason)}"
            )
        end
    end
  end

  defp fragment_from_content(entry, kind, source, content, remaining) do
    advice = Map.get(entry, "advice", %{})

    max_chars =
      min(normalize_integer(Map.get(advice, "max_chars"), @default_max_chars), remaining)

    content = to_string(content)
    raw_chars = String.length(content)
    selected = String.slice(content, 0, max_chars)
    truncated = raw_chars > String.length(selected)

    %{
      "id" => Map.fetch!(entry, "id"),
      "title" => Map.get(advice, "title") || Map.fetch!(entry, "id"),
      "kind" => kind,
      "source" => source,
      "content" => selected,
      "chars" => String.length(selected),
      "raw_chars" => raw_chars,
      "hash" => content_hash(content),
      "truncated" => truncated,
      "priority" => entry_priority(entry)
    }
  end

  defp handle_advice_error(entry, ctx, reason) do
    emit_failed(entry, ctx, reason)

    case get_in(entry, ["advice", "on_error"]) || "warn" do
      "skip" ->
        emit_skipped(entry, ctx, reason)
        {:ok, nil}

      "block" ->
        {:error, reason}

      _warn ->
        {:ok, warning_fragment(entry, reason)}
    end
  end

  defp warning_fragment(entry, reason) do
    title = get_in(entry, ["advice", "title"]) || Map.get(entry, "id", "hook")
    content = "Hook #{Map.get(entry, "id", "-")} failed: #{reason}"

    %{
      "id" => Map.get(entry, "id", "hook-warning"),
      "title" => "#{title} (warning)",
      "kind" => "warning",
      "source" => "hook-error",
      "content" => content,
      "chars" => String.length(content),
      "raw_chars" => String.length(content),
      "hash" => content_hash(content),
      "truncated" => false,
      "priority" => entry_priority(entry)
    }
  end

  defp entry_matches?(%{"enabled" => true, "event" => event, "pointcut" => pointcut}, event, ctx) do
    pointcut_matches?(pointcut || %{}, ctx)
  end

  defp entry_matches?(_entry, _event, _ctx), do: false

  defp pointcut_matches?(pointcut, ctx) when is_map(pointcut) do
    pointcut = stringify_keys(pointcut)

    target_matches?(Map.get(pointcut, "target"), ctx) and
      pointcut_value_matches?(Map.get(pointcut, "session"), Map.get(ctx, :session_key)) and
      pointcut_value_matches?(Map.get(pointcut, "channel"), Map.get(ctx, :channel)) and
      pointcut_value_matches?(Map.get(pointcut, "chat_id"), Map.get(ctx, :chat_id)) and
      pointcut_value_matches?(Map.get(pointcut, "parent_chat_id"), Map.get(ctx, :parent_chat_id)) and
      workspace_matches?(Map.get(pointcut, "workspace"), Map.get(ctx, :workspace))
  end

  defp pointcut_matches?(_pointcut, _ctx), do: false

  defp target_matches?(nil, _ctx), do: true
  defp target_matches?("", _ctx), do: true

  defp target_matches?("session:" <> session_key, ctx),
    do: pointcut_value_matches?(session_key, Map.get(ctx, :session_key))

  defp target_matches?(_target, _ctx), do: false

  defp pointcut_value_matches?(nil, _value), do: true
  defp pointcut_value_matches?("", _value), do: true
  defp pointcut_value_matches?(expected, value), do: to_string(expected) == to_string(value || "")

  defp workspace_matches?(nil, _value), do: true
  defp workspace_matches?("", _value), do: true

  defp workspace_matches?(expected, value) do
    Path.expand(to_string(expected)) == Path.expand(to_string(value || ""))
  end

  defp normalize_context(ctx) do
    %{
      session_key: Map.get(ctx, :session_key) || Map.get(ctx, "session_key"),
      channel: Map.get(ctx, :channel) || Map.get(ctx, "channel"),
      chat_id: Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id"),
      parent_chat_id: Map.get(ctx, :parent_chat_id) || Map.get(ctx, "parent_chat_id"),
      workspace: Map.get(ctx, :workspace) || Map.get(ctx, "workspace"),
      run_id: Map.get(ctx, :run_id) || Map.get(ctx, "run_id")
    }
  end

  defp hooks_entries(%{entries: entries}) when is_list(entries), do: entries
  defp hooks_entries(%{"entries" => entries}) when is_list(entries), do: entries
  defp hooks_entries(_hooks_data), do: []

  defp entry_priority(entry), do: normalize_integer(get_in(entry, ["advice", "priority"]), 100)

  defp normalize_event(:prompt_build_before), do: "prompt.build.before"
  defp normalize_event(event), do: to_string(event)

  defp normalize_registry_doc(doc) do
    doc = stringify_keys(doc)
    hooks = Map.get(doc, "hooks", [])
    hooks = if is_list(hooks), do: hooks, else: []
    %{"version" => normalize_integer(Map.get(doc, "version"), 1), "hooks" => hooks}
  end

  defp required_string(map, key) do
    case normalize_string(Map.get(map, key)) do
      nil -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp allowed_string(map, key, allowed, default) do
    value = normalize_string(Map.get(map, key)) || default

    cond do
      is_nil(value) -> {:error, "#{key} is required"}
      value in allowed -> {:ok, value}
      true -> {:error, "#{key} must be one of #{Enum.join(allowed, ", ")}"}
    end
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(_value), do: nil

  defp normalize_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_keys(_value), do: %{}

  defp workspace(opts), do: Keyword.get(opts, :workspace) || Workspace.root(opts)

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_doc(doc) do
    {:ok, Jason.encode!(doc, pretty: true)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp blocked_path?(expanded) do
    blocked =
      @blocked_paths
      |> Enum.map(&Path.expand/1)
      |> MapSet.new()

    if MapSet.member?(blocked, expanded) do
      true
    else
      MapSet.member?(blocked, realpath(expanded, blocked))
    end
  end

  defp realpath(path, blocked) do
    path
    |> Path.expand()
    |> resolve_path(blocked, MapSet.new())
  end

  defp resolve_path(path, blocked, seen) do
    expanded = Path.expand(path)

    cond do
      MapSet.member?(blocked, expanded) ->
        expanded

      MapSet.member?(seen, expanded) ->
        expanded

      true ->
        case Path.split(expanded) do
          [root | parts] -> resolve_components(root, parts, blocked, MapSet.put(seen, expanded))
          [] -> expanded
        end
    end
  end

  defp resolve_components(current, [], _blocked, _seen), do: Path.expand(current)

  defp resolve_components(current, [part | rest], blocked, seen) do
    candidate = Path.expand(Path.join(current, part))

    cond do
      MapSet.member?(blocked, candidate) ->
        candidate

      MapSet.member?(seen, candidate) ->
        candidate

      true ->
        case :file.read_link(String.to_charlist(candidate)) do
          {:ok, target} ->
            target = target |> List.to_string() |> expand_symlink_target(candidate)
            remainder = if rest == [], do: target, else: Path.join([target | rest])
            resolve_path(remainder, blocked, MapSet.put(seen, candidate))

          {:error, _reason} ->
            resolve_components(candidate, rest, blocked, seen)
        end
    end
  end

  defp expand_symlink_target(target, symlink_path) do
    case Path.type(target) do
      :absolute -> Path.expand(target)
      _relative -> Path.expand(target, Path.dirname(symlink_path))
    end
  end

  defp literal_content(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp literal_content(_value), do: nil

  defp diagnostic(type, path, message) do
    %{"type" => Atom.to_string(type), "path" => path, "message" => message}
  end

  defp emit_injected(entry, fragment, ctx) do
    Log.info(
      "context_hook.injected",
      %{
        "hook_id" => Map.get(entry, "id"),
        "kind" => Map.get(fragment, "kind"),
        "chars" => Map.get(fragment, "chars"),
        "truncated" => Map.get(fragment, "truncated", false)
      },
      observe_opts(ctx)
    )
  end

  defp emit_skipped(entry, ctx, reason) do
    Log.warning(
      "context_hook.skipped",
      %{"hook_id" => Map.get(entry, "id"), "reason" => reason},
      observe_opts(ctx)
    )
  end

  defp emit_failed(entry, ctx, reason) do
    Log.error(
      "context_hook.failed",
      %{"hook_id" => Map.get(entry, "id"), "reason" => reason},
      observe_opts(ctx)
    )
  end

  defp observe_opts(ctx) do
    []
    |> maybe_put(:workspace, Map.get(ctx, :workspace))
    |> maybe_put(:session_key, Map.get(ctx, :session_key))
    |> maybe_put(:channel, Map.get(ctx, :channel))
    |> maybe_put(:chat_id, Map.get(ctx, :chat_id))
    |> maybe_put(:parent_chat_id, Map.get(ctx, :parent_chat_id))
    |> maybe_put(:run_id, Map.get(ctx, :run_id))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp hash(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
  end

  defp content_hash(content) do
    :crypto.hash(:sha256, to_string(content))
    |> Base.encode16(case: :lower)
  end
end
