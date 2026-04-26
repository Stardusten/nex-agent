defmodule Nex.Agent.Subagent.Profile do
  @moduledoc """
  Runtime profile for a background subagent.

  Profiles are the stable contract between the owner agent and subagent runs:
  they describe when a subagent is useful, which prompt/model/tool surface it
  should use, how much parent context it should receive, and how the result is
  projected back.
  """

  @enforce_keys [:name, :description]
  defstruct name: nil,
            description: nil,
            prompt: nil,
            model_role: :inherit,
            model_key: nil,
            provider_options: [],
            tools_filter: :subagent,
            tool_allowlist: nil,
            context_mode: :blank,
            context_window: 12,
            return_mode: :inbound,
            max_iterations: nil,
            source: :unknown

  @type model_role :: :inherit | :default | :cheap | :advisor | atom() | String.t()
  @type tools_filter :: :subagent | :follow_up | :cron | :all
  @type context_mode :: :blank | :parent_recent
  @type return_mode :: :inbound | :silent

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          prompt: String.t() | nil,
          model_role: model_role(),
          model_key: String.t() | nil,
          provider_options: keyword(),
          tools_filter: tools_filter(),
          tool_allowlist: [String.t()] | nil,
          context_mode: context_mode(),
          context_window: pos_integer(),
          return_mode: return_mode(),
          max_iterations: pos_integer() | nil,
          source: atom() | String.t()
        }

  @valid_tools_filters [:subagent, :follow_up, :cron, :all]
  @valid_context_modes [:blank, :parent_recent]
  @valid_return_modes [:inbound, :silent]
  @provider_option_keys %{
    "max_tokens" => :max_tokens,
    "parallel_tool_calls" => :parallel_tool_calls,
    "reasoning-effort" => :reasoning_effort,
    "reasoning_effort" => :reasoning_effort,
    "temperature" => :temperature,
    "text-verbosity" => :text_verbosity,
    "text_verbosity" => :text_verbosity,
    "tool_choice" => :tool_choice,
    "top-k" => :top_k,
    "top_k" => :top_k,
    "top_p" => :top_p,
    "verbosity" => :verbosity
  }

  @spec from_map(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_map(default_name, attrs, opts \\ []) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    body_prompt = Keyword.get(opts, :prompt)
    source = Keyword.get(opts, :source, :config)

    name =
      attrs
      |> Map.get("name", default_name)
      |> normalize_name()

    description =
      attrs
      |> Map.get("description")
      |> normalize_string()

    prompt =
      attrs
      |> Map.get("prompt", body_prompt)
      |> normalize_string()

    cond do
      is_nil(name) ->
        {:error, {:invalid_subagent_profile, default_name, :missing_name}}

      is_nil(description) ->
        {:error, {:invalid_subagent_profile, name, :missing_description}}

      true ->
        {:ok,
         %__MODULE__{
           name: name,
           description: description,
           prompt: prompt,
           model_role:
             normalize_model_role(Map.get(attrs, "model_role") || Map.get(attrs, "model-role")),
           model_key:
             normalize_string(
               Map.get(attrs, "model_key") || Map.get(attrs, "model-key") ||
                 Map.get(attrs, "model")
             ),
           provider_options:
             normalize_provider_options(
               Map.get(attrs, "provider_options") || Map.get(attrs, "provider-options") || %{}
             ),
           tools_filter:
             normalize_tools_filter(
               Map.get(attrs, "tools_filter") || Map.get(attrs, "tools-filter")
             ),
           tool_allowlist:
             normalize_tool_allowlist(
               Map.get(attrs, "tool_allowlist") || Map.get(attrs, "tool-allowlist") ||
                 Map.get(attrs, "allowed_tools") || Map.get(attrs, "allowed-tools")
             ),
           context_mode:
             normalize_context_mode(
               Map.get(attrs, "context_mode") || Map.get(attrs, "context-mode")
             ),
           context_window:
             normalize_positive_integer(
               Map.get(attrs, "context_window") || Map.get(attrs, "context-window"),
               12
             ),
           return_mode:
             normalize_return_mode(Map.get(attrs, "return_mode") || Map.get(attrs, "return-mode")),
           max_iterations:
             normalize_optional_positive_integer(
               Map.get(attrs, "max_iterations") || Map.get(attrs, "max-iterations")
             ),
           source: source
         }}
    end
  end

  @spec builtin_profiles() :: %{String.t() => t()}
  def builtin_profiles do
    [
      %__MODULE__{
        name: "general",
        description:
          "Handle a bounded background task independently and return a concise result.",
        prompt: """
        You are a task-scoped background subagent child run. Complete the assigned task independently.

        Work in a focused way, use available tools when they materially help, and return a concise result with any important caveats.
        """,
        model_role: :inherit,
        tools_filter: :subagent,
        context_mode: :blank,
        return_mode: :inbound,
        source: :builtin
      },
      %__MODULE__{
        name: "code_reviewer",
        description:
          "Review code changes for correctness bugs, regressions, missing tests, and migration risks.",
        prompt: """
        You are a code review subagent. Focus on behavioral bugs, correctness risks, missing validation, missing tests, and migration hazards.

        Lead with concrete findings. Include file paths and line references when available. Keep style comments secondary.
        """,
        model_role: :advisor,
        tools_filter: :subagent,
        context_mode: :parent_recent,
        context_window: 16,
        return_mode: :inbound,
        source: :builtin
      },
      %__MODULE__{
        name: "researcher",
        description:
          "Research a question or unfamiliar area and report the most relevant findings.",
        prompt: """
        You are a research subagent. Gather the smallest useful set of facts, cite where they came from when possible, and separate confirmed facts from inference.
        """,
        model_role: :cheap,
        tools_filter: :subagent,
        context_mode: :blank,
        return_mode: :inbound,
        source: :builtin
      }
    ]
    |> Enum.into(%{}, fn profile -> {profile.name, profile} end)
  end

  @spec normalize_name(term()) :: String.t() | nil
  def normalize_name(value) do
    value
    |> normalize_string()
    |> case do
      nil -> nil
      name -> String.replace(name, ~r/[^a-zA-Z0-9_-]+/, "_")
    end
  end

  defp normalize_model_role(nil), do: :inherit
  defp normalize_model_role(:inherit), do: :inherit
  defp normalize_model_role(:default), do: :default
  defp normalize_model_role(:cheap), do: :cheap
  defp normalize_model_role(:advisor), do: :advisor

  defp normalize_model_role(role) when is_atom(role), do: role

  defp normalize_model_role(role) when is_binary(role) do
    case role |> String.trim() |> String.downcase() do
      "" -> :inherit
      "inherit" -> :inherit
      "default" -> :default
      "cheap" -> :cheap
      "advisor" -> :advisor
      other -> other
    end
  end

  defp normalize_model_role(_), do: :inherit

  defp normalize_tools_filter(nil), do: :subagent
  defp normalize_tools_filter(filter) when filter in @valid_tools_filters, do: filter

  defp normalize_tools_filter(filter) when is_binary(filter) do
    case filter |> String.trim() |> String.downcase() do
      "subagent" -> :subagent
      "follow_up" -> :follow_up
      "follow-up" -> :follow_up
      "cron" -> :cron
      "all" -> :all
      _ -> :subagent
    end
  end

  defp normalize_tools_filter(_), do: :subagent

  defp normalize_context_mode(nil), do: :blank
  defp normalize_context_mode(mode) when mode in @valid_context_modes, do: mode

  defp normalize_context_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "parent_recent" -> :parent_recent
      "recent" -> :parent_recent
      "blank" -> :blank
      "none" -> :blank
      _ -> :blank
    end
  end

  defp normalize_context_mode(_), do: :blank

  defp normalize_return_mode(nil), do: :inbound
  defp normalize_return_mode(mode) when mode in @valid_return_modes, do: mode

  defp normalize_return_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "inbound" -> :inbound
      "visible" -> :inbound
      "silent" -> :silent
      "none" -> :silent
      _ -> :inbound
    end
  end

  defp normalize_return_mode(_), do: :inbound

  defp normalize_tool_allowlist(nil), do: nil
  defp normalize_tool_allowlist(""), do: nil
  defp normalize_tool_allowlist(list) when is_list(list), do: normalize_string_list(list)

  defp normalize_tool_allowlist(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_string_list()
  end

  defp normalize_tool_allowlist(_), do: nil

  defp normalize_provider_options(options) when is_list(options) do
    options
    |> Enum.flat_map(fn
      {key, value} ->
        case normalize_option_key(key) do
          nil -> []
          normalized -> [{normalized, value}]
        end

      _other ->
        []
    end)
  end

  defp normalize_provider_options(options) when is_map(options) do
    options
    |> stringify_keys()
    |> Enum.flat_map(fn {key, value} ->
      case normalize_option_key(key) do
        nil -> []
        normalized -> [{normalized, value}]
      end
    end)
  end

  defp normalize_provider_options(_), do: []

  defp normalize_option_key(key) when is_atom(key), do: key

  defp normalize_option_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.downcase()
    |> then(&Map.get(@provider_option_keys, &1))
  end

  defp normalize_option_key(_key), do: nil

  defp normalize_string_list(list) do
    list
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_positive_integer(value, default) do
    normalize_optional_positive_integer(value) || default
  end

  defp normalize_optional_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_optional_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp normalize_optional_positive_integer(_), do: nil

  defp normalize_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value), do: value
end
