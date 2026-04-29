defmodule Nex.Agent.Config do
  @moduledoc """
  Configuration management for the runtime config contract.
  """

  alias Nex.Agent.LLM.ProviderProfile

  @default_config_path Path.join(System.get_env("HOME", "~"), ".nex/agent/config.json")

  @provider_type_atoms %{
    "openai-compatible" => :openai_compatible,
    "openai" => :openai,
    "anthropic" => :anthropic,
    "openai-codex" => :openai_codex,
    "openai-codex-custom" => :openai_codex_custom,
    "openrouter" => :openrouter,
    "ollama" => :ollama
  }
  @discord_table_modes ~w(raw ascii embed)
  @workbench_app_id_re ~r/^[a-z][a-z0-9_-]{1,63}$/

  defstruct max_iterations: 40,
            workspace: nil,
            channel: %{},
            gateway: %{},
            provider: %{},
            model: %{},
            subagents: %{},
            tools: %{}

  @type model_runtime :: %{
          model_key: String.t(),
          model_id: String.t(),
          provider_key: String.t(),
          provider_type: String.t(),
          provider: atom(),
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          context_window: pos_integer() | nil,
          auto_compact_token_limit: pos_integer() | nil,
          context_strategy: String.t() | nil,
          provider_options: keyword()
        }

  @type t :: %__MODULE__{
          max_iterations: pos_integer() | nil,
          workspace: String.t() | nil,
          channel: map(),
          gateway: map(),
          provider: map(),
          model: map(),
          subagents: map(),
          tools: map()
        }

  @spec default_config_path() :: String.t()
  def default_config_path, do: @default_config_path

  @spec config_path(keyword()) :: String.t()
  def config_path(opts \\ []) when is_list(opts) do
    Keyword.get(opts, :config_path) ||
      Application.get_env(:nex_agent, :config_path, @default_config_path)
  end

  @spec load(keyword()) :: t()
  def load(opts \\ []) when is_list(opts) do
    path = config_path(opts)

    if File.exists?(path) do
      case path |> File.read!() |> Jason.decode() do
        {:ok, data} when is_map(data) -> from_map(data)
        _ -> invalid()
      end
    else
      default()
    end
  end

  @spec save(t(), keyword()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = config, opts \\ []) when is_list(opts) do
    save_map(to_map(config), opts)
  end

  @spec read_map(keyword()) :: {:ok, map()} | {:error, term()}
  def read_map(opts \\ []) when is_list(opts) do
    path = config_path(opts)

    if File.exists?(path) do
      with {:ok, body} <- File.read(path),
           {:ok, %{} = data} <- Jason.decode(body) do
        {:ok, data}
      else
        {:ok, _other} ->
          {:error, :config_must_be_json_object}

        {:error, %Jason.DecodeError{} = error} ->
          {:error, {:invalid_json, Exception.message(error)}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, default_map()}
    end
  end

  @spec save_map(map(), keyword()) :: :ok | {:error, term()}
  def save_map(data, opts \\ []) when is_map(data) and is_list(opts) do
    path = config_path(opts)
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- Jason.encode(data, pretty: true),
         :ok <- File.write(tmp_path, encoded),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp_path)
        error
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    %{
      "max_iterations" => config.max_iterations,
      "workspace" => config.workspace,
      "channel" => config.channel,
      "gateway" => config.gateway,
      "provider" => config.provider,
      "model" => config.model,
      "subagents" => config.subagents,
      "tools" => config.tools
    }
  end

  @spec default() :: t()
  def default do
    %__MODULE__{
      max_iterations: 40,
      workspace: nil,
      channel: %{},
      gateway: default_gateway(),
      provider: %{
        "providers" => %{
          "openai" => %{"type" => "openai-compatible", "api_key" => nil, "base_url" => nil},
          "anthropic" => %{"type" => "anthropic", "api_key" => nil, "base_url" => nil},
          "openai-codex" => %{
            "type" => "openai-codex",
            "api_key" => nil,
            "base_url" => ProviderProfile.default_base_url(:openai_codex)
          },
          "openai-codex-custom" => %{
            "type" => "openai-codex-custom",
            "api_key" => nil,
            "base_url" => ProviderProfile.default_base_url(:openai_codex_custom)
          },
          "openrouter" => %{
            "type" => "openrouter",
            "api_key" => nil,
            "base_url" => "https://openrouter.ai/api/v1"
          },
          "ollama" => %{
            "type" => "ollama",
            "api_key" => nil,
            "base_url" => "http://localhost:11434"
          }
        }
      },
      model: %{
        "default_model" => "gpt-4o",
        "cheap_model" => "gpt-4o",
        "memory_model" => "gpt-4o",
        "advisor_model" => "gpt-4o",
        "models" => %{"gpt-4o" => %{"provider" => "openai", "id" => "gpt-4o"}}
      },
      subagents: %{"profiles" => %{}},
      tools: %{}
    }
  end

  @spec default_map() :: map()
  def default_map, do: default() |> to_map()

  @spec from_map(map()) :: t()
  def from_map(data) when is_map(data) do
    %__MODULE__{
      max_iterations: normalize_max_iterations(Map.get(data, "max_iterations")),
      workspace: normalize_optional_string(Map.get(data, "workspace")),
      channel: normalize_channels(Map.get(data, "channel")),
      gateway: normalize_gateway(Map.get(data, "gateway")),
      provider: normalize_provider_root(Map.get(data, "provider")),
      model: normalize_model_root(Map.get(data, "model")),
      subagents: normalize_subagents(Map.get(data, "subagents")),
      tools: normalize_tools(Map.get(data, "tools"))
    }
  end

  @spec model_role(t(), atom() | String.t()) :: model_runtime() | nil
  def model_role(%__MODULE__{} = config, role) do
    role_key =
      case role do
        :default -> "default_model"
        :cheap -> "cheap_model"
        :advisor -> "advisor_model"
        role when is_atom(role) -> Atom.to_string(role) <> "_model"
        role when is_binary(role) -> role
      end

    with model_key when is_binary(model_key) and model_key != "" <-
           Map.get(config.model || %{}, role_key),
         {:ok, runtime} <- resolve_model_runtime(config, model_key) do
      runtime
    else
      _ -> nil
    end
  end

  @spec default_model_runtime(t()) :: model_runtime() | nil
  def default_model_runtime(%__MODULE__{} = config), do: model_role(config, :default)

  @spec cheap_model_runtime(t()) :: model_runtime() | nil
  def cheap_model_runtime(%__MODULE__{} = config), do: model_role(config, :cheap)

  @spec memory_model_runtime(t()) :: model_runtime() | nil
  def memory_model_runtime(%__MODULE__{} = config) do
    model_role(config, :memory) || cheap_model_runtime(config) || default_model_runtime(config)
  end

  @spec advisor_model_runtime(t()) :: model_runtime() | nil
  def advisor_model_runtime(%__MODULE__{} = config), do: model_role(config, :advisor)

  @spec model_runtime(t(), String.t()) :: {:ok, model_runtime()} | {:error, :unknown_model}
  def model_runtime(%__MODULE__{} = config, model_key) when is_binary(model_key) do
    resolve_model_runtime(config, model_key)
  end

  @spec subagent_profile_config(t()) :: %{optional(String.t()) => map()}
  def subagent_profile_config(%__MODULE__{subagents: %{} = subagents}) do
    profiles =
      case Map.get(subagents, "profiles") do
        %{} = profiles -> profiles
        _ -> Map.drop(subagents, ["defaults"])
      end

    Enum.reduce(profiles, %{}, fn
      {name, %{} = attrs}, acc -> Map.put(acc, to_string(name), stringify_map_keys(attrs))
      {_name, _attrs}, acc -> acc
    end)
  end

  def subagent_profile_config(%__MODULE__{}), do: %{}

  @spec channel_instances(t()) :: %{optional(String.t()) => map()}
  def channel_instances(%__MODULE__{} = config), do: config.channel || %{}

  @spec enabled_channel_instances(t()) :: %{optional(String.t()) => map()}
  def enabled_channel_instances(%__MODULE__{} = config) do
    config
    |> channel_instances()
    |> Enum.filter(fn {_id, instance} -> Map.get(instance, "enabled", false) == true end)
    |> Map.new()
  end

  @spec channel_instance(t(), String.t() | atom()) :: map() | nil
  def channel_instance(%__MODULE__{} = config, instance_id) do
    Map.get(config.channel || %{}, to_string(instance_id))
  end

  @spec channel_runtime(t(), String.t() | atom()) :: map()
  def channel_runtime(%__MODULE__{} = config, instance_id) do
    case channel_instance(config, instance_id) do
      %{} = instance ->
        runtime = %{
          "type" => Map.get(instance, "type"),
          "streaming" => Map.get(instance, "streaming", default_streaming(instance)) == true
        }

        if Map.get(instance, "type") == "discord" do
          Map.put(runtime, "show_table_as", discord_show_table_as(instance))
        else
          runtime
        end

      _ ->
        %{"type" => nil, "streaming" => false}
    end
  end

  @spec channels_runtime(t()) :: %{optional(String.t()) => map()}
  def channels_runtime(%__MODULE__{} = config) do
    config
    |> channel_instances()
    |> Enum.into(%{}, fn {id, _instance} -> {id, channel_runtime(config, id)} end)
  end

  @spec channel_streaming?(t(), String.t() | atom()) :: boolean()
  def channel_streaming?(%__MODULE__{} = config, instance_id) do
    config
    |> channel_runtime(instance_id)
    |> Map.get("streaming", false)
    |> Kernel.==(true)
  end

  @spec channel_type(t(), String.t() | atom()) :: String.t() | nil
  def channel_type(%__MODULE__{} = config, instance_id) do
    case channel_instance(config, instance_id) do
      %{} = instance -> Map.get(instance, "type")
      _ -> nil
    end
  end

  @spec gateway_port(t()) :: pos_integer()
  def gateway_port(%__MODULE__{} = config) do
    case Map.get(config.gateway || %{}, "port") do
      port when is_integer(port) and port > 0 ->
        port

      port when is_binary(port) ->
        case Integer.parse(port) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> 18_790
        end

      _ ->
        18_790
    end
  end

  @spec workbench_runtime(t()) :: map()
  def workbench_runtime(%__MODULE__{} = config) do
    (config.gateway || %{})
    |> Map.get("workbench", default_workbench())
    |> normalize_workbench()
  end

  @spec workbench_app_config(t(), String.t() | atom()) :: map()
  def workbench_app_config(%__MODULE__{} = config, app_id) do
    config
    |> workbench_runtime()
    |> Map.get("apps", %{})
    |> Map.get(to_string(app_id), %{})
  end

  @spec get_max_iterations(t()) :: pos_integer()
  def get_max_iterations(%__MODULE__{} = config) do
    case config.max_iterations do
      n when is_integer(n) and n > 0 -> n
      _ -> 40
    end
  end

  @spec configured_workspace(t()) :: String.t() | nil
  def configured_workspace(%__MODULE__{} = config), do: config.workspace

  @spec get_tool_config(t(), String.t()) :: String.t() | nil
  def get_tool_config(%__MODULE__{tools: tools}, key) do
    tools
    |> Map.get(key)
    |> resolve_secret()
  end

  @spec web_search_provider_config(t() | nil) :: map()
  def web_search_provider_config(%__MODULE__{tools: tools}) when is_map(tools) do
    {provider, config} = selected_tool_backend(tools, "web_search", "duckduckgo")
    normalize_web_search_provider_config(provider, config)
  end

  def web_search_provider_config(_config) do
    %{"provider" => "duckduckgo"}
  end

  @spec image_generation_provider_config(t() | nil) :: map()
  def image_generation_provider_config(%__MODULE__{tools: tools}) when is_map(tools) do
    {provider, config} = selected_tool_backend(tools, "image_generation", "codex")
    normalize_image_generation_provider_config(provider, config)
  end

  def image_generation_provider_config(_config) do
    %{"provider" => "codex", "output_format" => "png"}
  end

  @spec file_access_allowed_roots(t() | nil) :: [String.t()]
  def file_access_allowed_roots(%__MODULE__{tools: tools}) when is_map(tools) do
    tools
    |> Map.get("file_access", %{})
    |> normalize_file_access_config()
    |> Map.get("allowed_roots", [])
  end

  def file_access_allowed_roots(_config), do: []

  @spec request_trace(t()) :: map()
  def request_trace(%__MODULE__{}), do: %{"enabled" => false}

  @spec set(t(), atom(), term()) :: t()
  def set(%__MODULE__{} = config, :default_workspace, value) when is_binary(value) do
    %{config | workspace: Path.expand(value)}
  end

  def set(%__MODULE__{} = config, :gateway_port, value) when is_integer(value) and value > 0 do
    %{config | gateway: Map.put(config.gateway || %{}, "port", value)}
  end

  def set(%__MODULE__{} = config, :workbench_port, value) when is_integer(value) and value > 0 do
    gateway = config.gateway || %{}
    workbench = gateway |> Map.get("workbench", default_workbench()) |> normalize_workbench()

    %{config | gateway: Map.put(gateway, "workbench", Map.put(workbench, "port", value))}
  end

  def set(%__MODULE__{} = config, :max_iterations, value) when is_integer(value) and value > 0 do
    %{config | max_iterations: value}
  end

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = config) do
    valid_new_shape?(config) and valid_default_model?(config) and valid_channels?(config)
  end

  @spec provider_type_to_atom(String.t() | atom() | nil) :: atom()
  def provider_type_to_atom(type) when is_atom(type), do: type

  def provider_type_to_atom(type) when is_binary(type) do
    Map.get(@provider_type_atoms, type, :openai)
  end

  def provider_type_to_atom(_type), do: :openai

  defp invalid do
    %__MODULE__{
      max_iterations: nil,
      workspace: nil,
      channel: %{},
      gateway: %{},
      provider: %{},
      model: %{},
      subagents: %{},
      tools: %{}
    }
  end

  defp resolve_model_runtime(%__MODULE__{} = config, model_key) do
    models = Map.get(config.model || %{}, "models", %{})
    model_config = Map.get(models, model_key)

    with %{} <- model_config,
         provider_key when is_binary(provider_key) and provider_key != "" <-
           Map.get(model_config, "provider"),
         provider_config when is_map(provider_config) <-
           get_in(config.provider || %{}, ["providers", provider_key]) do
      provider_type = Map.get(provider_config, "type", "openai-compatible")
      provider = provider_type_to_atom(provider_type)
      model_id = normalize_optional_string(Map.get(model_config, "id")) || model_key

      {:ok,
       %{
         model_key: model_key,
         model_id: model_id,
         provider_key: provider_key,
         provider_type: provider_type,
         provider: provider,
         api_key: provider_api_key(provider, provider_config),
         base_url: provider_base_url(provider, provider_config),
         context_window: model_context_window(model_config),
         auto_compact_token_limit: model_auto_compact_token_limit(model_config),
         context_strategy: model_context_strategy(model_config),
         provider_options: provider_options(provider_config, model_config)
       }}
    else
      _ -> {:error, :unknown_model}
    end
  end

  defp provider_api_key(:openai_codex, provider_config) do
    resolve_secret(Map.get(provider_config, "api_key")) ||
      ProviderProfile.default_api_key(:openai_codex)
  end

  defp provider_api_key(:openai_codex_custom, provider_config) do
    resolve_secret(Map.get(provider_config, "api_key")) ||
      ProviderProfile.default_api_key(:openai_codex_custom)
  end

  defp provider_api_key(:anthropic, provider_config),
    do: resolve_secret(Map.get(provider_config, "api_key")) || System.get_env("ANTHROPIC_API_KEY")

  defp provider_api_key(:openai, provider_config),
    do: resolve_secret(Map.get(provider_config, "api_key")) || System.get_env("OPENAI_API_KEY")

  defp provider_api_key(:openai_compatible, provider_config),
    do: resolve_secret(Map.get(provider_config, "api_key")) || System.get_env("OPENAI_API_KEY")

  defp provider_api_key(:ollama, _provider_config), do: nil

  defp provider_api_key(_provider, provider_config),
    do: resolve_secret(Map.get(provider_config, "api_key"))

  defp provider_base_url(:openai_codex, provider_config) do
    normalize_optional_string(Map.get(provider_config, "base_url")) ||
      ProviderProfile.default_base_url(:openai_codex)
  end

  defp provider_base_url(:openai_codex_custom, provider_config) do
    normalize_optional_string(Map.get(provider_config, "base_url")) ||
      ProviderProfile.default_base_url(:openai_codex_custom)
  end

  defp provider_base_url(:openrouter, provider_config) do
    normalize_optional_string(Map.get(provider_config, "base_url")) ||
      "https://openrouter.ai/api/v1"
  end

  defp provider_base_url(:ollama, provider_config) do
    normalize_optional_string(Map.get(provider_config, "base_url")) ||
      "http://localhost:11434"
  end

  defp provider_base_url(_provider, provider_config),
    do: normalize_optional_string(Map.get(provider_config, "base_url"))

  defp provider_options(provider_config, model_config) do
    provider_options =
      provider_config
      |> Map.drop(["type", "api_key", "base_url"])
      |> stringify_map_keys()

    model_options =
      model_config
      |> Map.drop(model_runtime_keys())
      |> stringify_map_keys()

    provider_options
    |> Map.merge(model_options)
    |> Enum.map(fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp model_runtime_keys do
    [
      "provider",
      "id",
      "context_window",
      "context_tokens",
      "max_context_tokens",
      "context_limit",
      "model_context_window",
      "auto_compact_token_limit",
      "model_auto_compact_token_limit",
      "context_strategy"
    ]
  end

  defp model_context_window(model_config) do
    model_config
    |> first_positive_integer([
      "context_window",
      "model_context_window",
      "context_tokens",
      "max_context_tokens",
      "context_limit"
    ])
  end

  defp model_auto_compact_token_limit(model_config) do
    first_positive_integer(model_config, [
      "auto_compact_token_limit",
      "model_auto_compact_token_limit"
    ])
  end

  defp model_context_strategy(model_config) do
    model_config
    |> Map.get("context_strategy")
    |> normalize_optional_string()
  end

  defp first_positive_integer(model_config, keys) do
    Enum.find_value(keys, fn key -> normalize_positive_integer(Map.get(model_config, key)) end)
  end

  defp valid_new_shape?(%__MODULE__{} = config) do
    is_integer(config.max_iterations) and config.max_iterations > 0 and
      is_map(config.channel) and is_map(config.gateway) and is_map(config.provider) and
      is_map(config.model) and is_map(config.subagents) and is_map(config.tools)
  end

  defp valid_default_model?(%__MODULE__{} = config) do
    case default_model_runtime(config) do
      nil -> false
      %{provider: :ollama} -> true
      %{api_key: key} when is_binary(key) and key != "" -> true
      _ -> false
    end
  end

  defp valid_channels?(%__MODULE__{} = config) do
    config
    |> channel_instances()
    |> Enum.all?(fn {_id, instance} -> valid_channel_instance?(instance) end)
  end

  defp valid_channel_instance?(%{"enabled" => true, "type" => "feishu"} = instance) do
    present?(Map.get(instance, "app_id")) and present?(Map.get(instance, "app_secret"))
  end

  defp valid_channel_instance?(%{"enabled" => true, "type" => "discord"} = instance) do
    present?(Map.get(instance, "token"))
  end

  defp valid_channel_instance?(%{"type" => type}) when type in ["feishu", "discord"], do: true
  defp valid_channel_instance?(_instance), do: false

  defp normalize_max_iterations(value) when is_integer(value) and value > 0, do: value

  defp normalize_max_iterations(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_max_iterations(_value), do: nil

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_positive_integer(_value), do: nil

  defp normalize_channels(channels) when is_map(channels) do
    channels
    |> stringify_map_keys()
    |> Enum.reduce(%{}, fn {id, instance}, acc ->
      case normalize_channel_instance(instance) do
        nil -> acc
        normalized -> Map.put(acc, id, normalized)
      end
    end)
  end

  defp normalize_channels(_channels), do: %{}

  defp normalize_channel_instance(%{} = instance) do
    instance = stringify_map_keys(instance)

    case normalize_optional_string(Map.get(instance, "type")) do
      type when type in ["feishu", "discord"] ->
        normalized =
          instance
          |> Map.put("type", type)
          |> Map.put("enabled", Map.get(instance, "enabled", false) == true)
          |> normalize_channel_secret("token")
          |> normalize_channel_secret("app_secret")

        if type == "discord" do
          Map.put(normalized, "show_table_as", discord_show_table_as(normalized))
        else
          normalized
        end

      _ ->
        nil
    end
  end

  defp normalize_channel_instance(_instance), do: nil

  defp normalize_channel_secret(instance, key) do
    case Map.get(instance, key) do
      %{} = secret -> Map.put(instance, key, resolve_secret(secret))
      _ -> instance
    end
  end

  defp normalize_gateway(gateway) when is_map(gateway) do
    gateway
    |> stringify_map_keys()
    |> Map.put_new("port", 18_790)
    |> Map.update("workbench", default_workbench(), &normalize_workbench/1)
  end

  defp normalize_gateway(_gateway), do: default_gateway()

  defp normalize_workbench(%{} = workbench) do
    workbench = stringify_map_keys(workbench)

    %{
      "enabled" => Map.get(workbench, "enabled", false) == true,
      "host" => normalize_workbench_host(Map.get(workbench, "host")),
      "port" => normalize_port(Map.get(workbench, "port"), 50_051),
      "apps" => normalize_workbench_apps(Map.get(workbench, "apps"))
    }
  end

  defp normalize_workbench(_workbench), do: default_workbench()

  defp normalize_workbench_apps(apps) when is_map(apps) do
    apps
    |> stringify_map_keys()
    |> Enum.reduce(%{}, fn
      {app_id, %{} = config}, acc ->
        if Regex.match?(@workbench_app_id_re, app_id) do
          Map.put(acc, app_id, normalize_workbench_app_config(config))
        else
          acc
        end

      {_app_id, _config}, acc ->
        acc
    end)
  end

  defp normalize_workbench_apps(_apps), do: %{}

  defp normalize_workbench_app_config(%{} = config) do
    config = stringify_map_keys(config)

    case normalize_path_string(Map.get(config, "root")) do
      nil -> Map.delete(config, "root")
      root -> Map.put(config, "root", root)
    end
  end

  defp normalize_provider_root(%{} = provider) do
    providers =
      provider
      |> stringify_map_keys()
      |> Map.get("providers", %{})
      |> normalize_provider_entries()

    %{"providers" => providers}
  end

  defp normalize_provider_root(_provider), do: %{}

  defp normalize_provider_entries(providers) when is_map(providers) do
    providers
    |> stringify_map_keys()
    |> Enum.reduce(%{}, fn {key, config}, acc ->
      case normalize_provider_entry(config) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp normalize_provider_entries(_providers), do: %{}

  defp normalize_provider_entry(%{} = config) do
    config = stringify_map_keys(config)
    type = normalize_optional_string(Map.get(config, "type"))

    if Map.has_key?(@provider_type_atoms, type) do
      config
      |> Map.put("type", type)
      |> Map.update("api_key", nil, &normalize_secret_spec/1)
      |> Map.update("base_url", nil, &normalize_optional_string/1)
    end
  end

  defp normalize_provider_entry(_config), do: nil

  defp normalize_model_root(%{} = model) do
    model = stringify_map_keys(model)

    %{
      "default_model" => normalize_optional_string(Map.get(model, "default_model")),
      "cheap_model" => normalize_optional_string(Map.get(model, "cheap_model")),
      "memory_model" => normalize_optional_string(Map.get(model, "memory_model")),
      "advisor_model" => normalize_optional_string(Map.get(model, "advisor_model")),
      "models" => normalize_model_entries(Map.get(model, "models"))
    }
  end

  defp normalize_model_root(_model), do: %{}

  defp normalize_model_entries(models) when is_map(models) do
    models
    |> stringify_map_keys()
    |> Enum.reduce(%{}, fn {key, config}, acc ->
      case normalize_model_entry(key, config) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp normalize_model_entries(_models), do: %{}

  defp normalize_model_entry(key, %{} = config) do
    config = stringify_map_keys(config)

    case normalize_optional_string(Map.get(config, "provider")) do
      nil ->
        nil

      provider ->
        config
        |> Map.put("provider", provider)
        |> Map.put("id", normalize_optional_string(Map.get(config, "id")) || key)
    end
  end

  defp normalize_model_entry(_key, _config), do: nil

  defp normalize_subagents(%{} = subagents) do
    subagents
    |> stringify_map_keys()
    |> Map.update("profiles", %{}, fn
      %{} = profiles -> normalize_subagent_profile_entries(profiles)
      _ -> %{}
    end)
  end

  defp normalize_subagents(_subagents), do: %{"profiles" => %{}}

  defp normalize_subagent_profile_entries(profiles) when is_map(profiles) do
    profiles
    |> stringify_map_keys()
    |> Enum.reduce(%{}, fn
      {name, %{} = attrs}, acc -> Map.put(acc, name, stringify_map_keys(attrs))
      {_name, _attrs}, acc -> acc
    end)
  end

  defp normalize_subagent_profile_entries(_profiles), do: %{}

  defp normalize_tools(tools) when is_map(tools) do
    tools = stringify_map_keys(tools)

    case Map.fetch(tools, "file_access") do
      {:ok, config} -> Map.put(tools, "file_access", normalize_file_access_config(config))
      :error -> tools
    end
  end

  defp normalize_tools(_tools), do: %{}

  defp normalize_file_access_config(%{} = config) do
    config = stringify_map_keys(config)

    %{
      "allowed_roots" => normalize_allowed_roots(Map.get(config, "allowed_roots"))
    }
  end

  defp normalize_file_access_config(_config), do: %{"allowed_roots" => []}

  defp normalize_allowed_roots(roots) when is_list(roots) do
    roots
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp normalize_allowed_roots(_roots), do: []

  defp selected_tool_backend(tools, tool_name, default_provider) do
    tool_config =
      tools
      |> Map.get(tool_name, %{})
      |> normalize_tool_config()

    provider = normalize_optional_string(Map.get(tool_config, "provider")) || default_provider

    provider_config =
      tool_config
      |> Map.get("providers")
      |> normalize_tool_backend_table()
      |> Map.get(provider, %{})

    {provider, provider_config}
  end

  defp normalize_tool_config(%{} = config), do: stringify_map_keys(config)
  defp normalize_tool_config(_config), do: %{}

  defp normalize_tool_backend_table(%{} = providers), do: stringify_map_keys(providers)
  defp normalize_tool_backend_table(_providers), do: %{}

  defp normalize_web_search_provider_config("codex", config) when is_map(config) do
    %{
      "provider" => "codex",
      "mode" => normalize_web_search_mode(Map.get(config, "mode")),
      "allowed_domains" => normalize_allowed_domains(Map.get(config, "allowed_domains")),
      "user_location" => normalize_user_location(Map.get(config, "user_location"))
    }
  end

  defp normalize_web_search_provider_config(provider, _config) do
    %{"provider" => provider}
  end

  defp normalize_image_generation_provider_config(provider, config) when is_map(config) do
    %{
      "provider" => provider,
      "output_format" =>
        normalize_image_generation_output_format(Map.get(config, "output_format"))
    }
  end

  defp normalize_web_search_mode("cached"), do: "cached"
  defp normalize_web_search_mode("disabled"), do: "disabled"
  defp normalize_web_search_mode(_), do: "live"

  defp normalize_image_generation_output_format("jpeg"), do: "jpeg"
  defp normalize_image_generation_output_format("webp"), do: "webp"
  defp normalize_image_generation_output_format(_), do: "png"

  defp normalize_secret_spec(%{} = secret), do: stringify_map_keys(secret)
  defp normalize_secret_spec(value), do: normalize_optional_string(value)

  defp resolve_secret(%{"env" => env_var}) when is_binary(env_var), do: System.get_env(env_var)
  defp resolve_secret(%{env: env_var}) when is_binary(env_var), do: System.get_env(env_var)
  defp resolve_secret(value), do: normalize_optional_string(value)

  defp normalize_allowed_domains(domains) when is_list(domains) do
    domains
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_allowed_domains(_domains), do: []

  defp normalize_user_location(%{} = location) do
    normalized =
      location
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        key = to_string(key)

        if key in ["country", "region", "city", "timezone"] do
          case value |> to_string() |> String.trim() do
            "" -> acc
            normalized_value -> Map.put(acc, key, normalized_value)
          end
        else
          acc
        end
      end)

    if map_size(normalized) == 0, do: nil, else: normalized
  end

  defp normalize_user_location(_location), do: nil

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      value =
        cond do
          is_map(value) -> stringify_map_keys(value)
          is_list(value) -> Enum.map(value, &stringify_nested/1)
          true -> value
        end

      {to_string(key), value}
    end)
  end

  defp stringify_nested(value) when is_map(value), do: stringify_map_keys(value)
  defp stringify_nested(value), do: value

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalize_optional_string(_value), do: nil

  defp normalize_path_string(value) do
    case normalize_optional_string(value) do
      nil -> nil
      path -> Path.expand(path)
    end
  end

  defp default_gateway, do: %{"port" => 18_790, "workbench" => default_workbench()}

  defp default_workbench do
    %{"enabled" => false, "host" => "127.0.0.1", "port" => 50_051, "apps" => %{}}
  end

  defp normalize_workbench_host(value) do
    case normalize_optional_string(value) do
      "127.0.0.1" -> "127.0.0.1"
      _ -> "127.0.0.1"
    end
  end

  defp normalize_port(value, _default) when is_integer(value) and value > 0 and value <= 65_535,
    do: value

  defp normalize_port(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 and parsed <= 65_535 -> parsed
      _ -> default
    end
  end

  defp normalize_port(_value, default), do: default

  defp default_streaming(%{"type" => "feishu"}), do: true
  defp default_streaming(%{"type" => "discord"}), do: false
  defp default_streaming(_instance), do: false

  defp discord_show_table_as(%{} = instance) do
    instance
    |> Map.get("show_table_as")
    |> normalize_optional_string()
    |> then(fn
      nil -> nil
      mode -> String.downcase(mode)
    end)
    |> case do
      mode when mode in @discord_table_modes -> mode
      _ -> "ascii"
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
