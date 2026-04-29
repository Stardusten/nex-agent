defmodule Nex.Agent.Conversation.Command.StatusView do
  @moduledoc """
  Compact Markdown views for deterministic chat commands.
  """

  alias Nex.Agent.{Runtime.Config, Turn.ContextBuilder, Conversation.Session}
  alias Nex.Agent.Interface.Channel.Registry, as: ChannelRegistry
  alias Nex.Agent.Conversation.RunControl

  @history_limit 50
  @status_model_limit 6
  @role_model_keys ["default_model", "cheap_model", "advisor_model", "memory_model"]

  @type model_source :: :session_override | :default | :first_available | :none

  @type model_resolution :: %{
          required(:runtime) => Config.model_runtime() | nil,
          required(:source) => model_source(),
          required(:invalid_override_key) => String.t() | nil
        }

  @type model_entry :: %{
          required(:index) => pos_integer(),
          required(:key) => String.t(),
          required(:model_id) => String.t(),
          required(:provider_key) => String.t(),
          required(:current?) => boolean()
        }

  @spec effective_model(Config.t(), Session.t()) :: model_resolution()
  def effective_model(%Config{} = config, %Session{} = session) do
    override_key = Session.model_override(session)

    case override_key && Config.model_runtime(config, override_key) do
      {:ok, runtime} ->
        %{runtime: runtime, source: :session_override, invalid_override_key: nil}

      _ ->
        default_or_first_available(config, override_key)
    end
  end

  @spec model_entries(Config.t(), Session.t()) :: [model_entry()]
  def model_entries(%Config{} = config, %Session{} = session) do
    resolution = effective_model(config, session)
    current_key = resolution.runtime && resolution.runtime.model_key

    config
    |> ordered_model_keys(current_key)
    |> Enum.reduce([], fn model_key, acc ->
      case Config.model_runtime(config, model_key) do
        {:ok, runtime} ->
          [
            %{
              key: runtime.model_key,
              model_id: runtime.model_id,
              provider_key: runtime.provider_key,
              current?: runtime.model_key == current_key
            }
            | acc
          ]

        {:error, _reason} ->
          acc
      end
    end)
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, index} -> Map.put(entry, :index, index) end)
  end

  @spec model_runtime_for_session(Config.t(), Session.t()) :: Config.model_runtime() | nil
  def model_runtime_for_session(%Config{} = config, %Session{} = session) do
    config
    |> effective_model(session)
    |> Map.get(:runtime)
  end

  @spec resolve_model_ref(Config.t(), Session.t(), String.t()) ::
          {:ok, model_entry()} | {:error, :unknown_model, [model_entry()]}
  def resolve_model_ref(%Config{} = config, %Session{} = session, ref) when is_binary(ref) do
    entries = model_entries(config, session)
    trimmed = String.trim(ref)

    entry =
      case Integer.parse(trimmed) do
        {index, ""} when index > 0 ->
          Enum.find(entries, &(Map.fetch!(&1, :index) == index))

        _ ->
          Enum.find(entries, &(Map.fetch!(&1, :key) == trimmed)) ||
            Enum.find(
              entries,
              &(String.downcase(Map.fetch!(&1, :key)) == String.downcase(trimmed))
            )
      end

    case entry do
      nil -> {:error, :unknown_model, entries}
      entry -> {:ok, entry}
    end
  end

  @spec render_model(Config.t(), Session.t()) :: String.t()
  def render_model(%Config{} = config, %Session{} = session) do
    resolution = effective_model(config, session)
    entries = model_entries(config, session)
    current = current_entry(entries)
    default_key = config.model |> Map.get("default_model") |> normalize_string()

    [
      "**Model**",
      "Current: #{format_current_model(current, resolution)}",
      default_line(default_key, entries),
      invalid_override_line(resolution),
      "",
      "**Available**",
      render_model_entries(entries),
      "",
      "Use: `/model 1`, `/model #{current_key(current) || "<name>"}`, or `/model reset`"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  @spec render_model_switched(model_entry()) :: String.t()
  def render_model_switched(%{} = entry) do
    """
    Model switched to **[#{entry.index}] #{entry.key}** for this session.

    Your next message in this chat will use #{entry.key}. No `/new` needed.
    Any task already running will finish with the model it started with.
    """
    |> String.trim()
  end

  @spec render_model_reset(Config.t(), Session.t()) :: String.t()
  def render_model_reset(%Config{} = config, %Session{} = session) do
    resolution = effective_model(config, session)
    entries = model_entries(config, session)
    current = current_entry(entries)

    label =
      case {current, resolution.source} do
        {%{} = entry, :default} -> "**[#{entry.index}] #{entry.key}** · default"
        {%{} = entry, _source} -> "**[#{entry.index}] #{entry.key}**"
        _ -> "unavailable"
      end

    """
    Model override cleared.

    Current model: #{label}
    Your next message in this chat will use the default model. No `/new` needed.
    """
    |> String.trim()
  end

  @spec render_unknown_model(String.t(), [model_entry()]) :: String.t()
  def render_unknown_model(ref, entries) when is_binary(ref) do
    available =
      entries
      |> Enum.map(fn entry -> "#{entry.index}: #{entry.key}" end)
      |> Enum.join(", ")

    """
    Unknown model: #{String.trim(ref)}

    Available: #{if available == "", do: "none", else: available}
    Use `/model <number>`, `/model <name>`, or `/model reset`.
    """
    |> String.trim()
  end

  @spec render_status(Config.t(), Session.t(), RunControl.Run.t() | nil, String.t(), keyword()) ::
          String.t()
  def render_status(%Config{} = config, %Session{} = session, run, evidence, opts \\ []) do
    workspace = Keyword.get(opts, :workspace)
    resolution = effective_model(config, session)
    entries = model_entries(config, session)
    current = current_entry(entries)

    [
      "**Status**",
      status_summary(run, config, session, current, resolution, workspace),
      "",
      tool_section(run),
      "**Channels**",
      render_channels(config),
      "",
      "**Models**",
      render_status_models(entries),
      "",
      evidence
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp default_or_first_available(config, invalid_override_key) do
    case Config.default_model_runtime(config) do
      nil ->
        case first_available_runtime(config) do
          nil ->
            %{runtime: nil, source: :none, invalid_override_key: invalid_override_key}

          runtime ->
            %{
              runtime: runtime,
              source: :first_available,
              invalid_override_key: invalid_override_key
            }
        end

      runtime ->
        %{runtime: runtime, source: :default, invalid_override_key: invalid_override_key}
    end
  end

  defp first_available_runtime(%Config{} = config) do
    config
    |> all_model_keys()
    |> Enum.find_value(fn model_key ->
      case Config.model_runtime(config, model_key) do
        {:ok, runtime} -> runtime
        {:error, _reason} -> nil
      end
    end)
  end

  defp ordered_model_keys(config, current_key) do
    role_keys =
      @role_model_keys
      |> Enum.map(&get_in(config.model || %{}, [&1]))
      |> Enum.map(&normalize_string/1)

    ([current_key] ++ role_keys ++ all_model_keys(config))
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp all_model_keys(%Config{} = config) do
    config.model
    |> Map.get("models", %{})
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp current_entry(entries), do: Enum.find(entries, &Map.fetch!(&1, :current?))
  defp current_key(%{} = entry), do: Map.fetch!(entry, :key)
  defp current_key(_entry), do: nil

  defp format_current_model(nil, %{source: :none}), do: "unavailable"

  defp format_current_model(%{} = entry, %{source: source}) do
    "**[#{entry.index}] #{entry.key}** · #{model_source_label(source)}"
  end

  defp model_source_label(:session_override), do: "session override"
  defp model_source_label(:default), do: "default"
  defp model_source_label(:first_available), do: "first available"
  defp model_source_label(:none), do: "unavailable"

  defp default_line(nil, _entries), do: nil

  defp default_line(default_key, entries) do
    case Enum.find(entries, &(Map.fetch!(&1, :key) == default_key)) do
      nil -> "Default: #{default_key}"
      entry -> "Default: [#{entry.index}] #{entry.key}"
    end
  end

  defp invalid_override_line(%{invalid_override_key: key}) when is_binary(key) do
    "Saved override #{key} is no longer available; using default."
  end

  defp invalid_override_line(_resolution), do: nil

  defp render_model_entries([]), do: "No configured models."

  defp render_model_entries(entries) do
    entries
    |> Enum.map(fn entry ->
      line = "[#{entry.index}] #{entry.key} · #{entry.provider_key} / #{entry.model_id}"

      if entry.current? do
        "> **#{line}**"
      else
        line
      end
    end)
    |> Enum.join("\n")
  end

  defp status_summary(nil, config, session, current, resolution, workspace) do
    model = status_model_label(current)
    context = context_summary(config, session, resolution, workspace)
    "Idle · model #{model} · context #{context}"
  end

  defp status_summary(%RunControl.Run{} = run, config, session, current, resolution, workspace) do
    elapsed_seconds = max(div(System.system_time(:millisecond) - run.started_at_ms, 1000), 0)
    queue = if run.queued_count > 0, do: " · queue #{run.queued_count}", else: ""

    [
      "Running · #{run.current_phase} · #{elapsed_seconds}s#{queue}",
      "Model: #{status_model_label(current)} · #{model_source_label(resolution.source)}",
      "Context: #{context_summary(config, session, resolution, workspace)}"
    ]
  end

  defp status_model_label(%{} = entry), do: "**[#{entry.index}] #{entry.key}**"
  defp status_model_label(_entry), do: "**unavailable**"

  defp tool_section(%RunControl.Run{current_tool: tool}) when is_binary(tool) and tool != "" do
    ["", "**Tool**", tool, ""]
  end

  defp tool_section(_run), do: nil

  defp render_channels(%Config{} = config) do
    config
    |> Config.enabled_channel_instances()
    |> Enum.sort_by(fn {id, _instance} -> id end)
    |> Enum.map(fn {id, instance} ->
      status = if ChannelRegistry.whereis(id), do: "connected", else: "disconnected"
      "#{id} #{status} (#{Map.get(instance, "type", "unknown")})"
    end)
    |> compact_join(4, " · ", "none")
  end

  defp render_status_models(entries) do
    {visible, hidden} = Enum.split(entries, @status_model_limit)

    current_line =
      visible
      |> Enum.find(&Map.fetch!(&1, :current?))
      |> case do
        nil -> nil
        entry -> "> **[#{entry.index}] #{entry.key}**"
      end

    rest =
      visible
      |> Enum.reject(&Map.fetch!(&1, :current?))
      |> Enum.map(fn entry -> "[#{entry.index}] #{entry.key}" end)
      |> Enum.join(" · ")

    suffix =
      case length(hidden) do
        0 -> nil
        count -> "+#{count} more · `/model` for full list"
      end

    [current_line, rest, suffix]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
    |> case do
      "" -> "No configured models."
      text -> text
    end
  end

  defp context_summary(config, session, resolution, workspace) do
    used_tokens = estimate_context_tokens(session, workspace)
    limit = context_limit(config, resolution.runtime)

    if is_integer(limit) and limit > 0 do
      left = max(limit - used_tokens, 0)
      "~#{format_tokens(used_tokens)} used / ~#{format_tokens(left)} left"
    else
      "~#{format_tokens(used_tokens)} used / limit unknown"
    end
  end

  defp estimate_context_tokens(%Session{} = session, workspace) do
    system_prompt_chars =
      case workspace do
        workspace when is_binary(workspace) ->
          ContextBuilder.build_system_prompt(workspace: workspace) |> String.length()

        _ ->
          0
      end

    history_chars =
      session
      |> Session.get_history(@history_limit)
      |> Enum.map(&message_chars/1)
      |> Enum.sum()

    div(system_prompt_chars + history_chars + 3, 4)
  rescue
    _ -> 0
  end

  defp message_chars(message) when is_map(message) do
    message
    |> Map.get("content", "")
    |> case do
      value when is_binary(value) -> String.length(value)
      value -> value |> inspect(printable_limit: 500, limit: 50) |> String.length()
    end
  end

  defp message_chars(_message), do: 0

  defp context_limit(_config, nil), do: nil

  defp context_limit(_config, runtime) when is_map(runtime) do
    runtime
    |> Map.get(:context_window, Map.get(runtime, "context_window"))
    |> normalize_positive_integer()
  end

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp normalize_positive_integer(_value), do: nil

  defp format_tokens(tokens) when is_integer(tokens) and tokens >= 1000 do
    value = tokens / 1000

    if rem(tokens, 1000) == 0 do
      "#{trunc(value)}k"
    else
      :erlang.float_to_binary(value, decimals: 1) <> "k"
    end
  end

  defp format_tokens(tokens) when is_integer(tokens), do: Integer.to_string(tokens)

  defp compact_join(items, limit, separator, empty) do
    {visible, hidden} = Enum.split(items, limit)

    case visible do
      [] ->
        empty

      _ ->
        suffix =
          case length(hidden) do
            0 -> []
            count -> ["+#{count} more"]
          end

        Enum.join(visible ++ suffix, separator)
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_string(_value), do: nil
end
