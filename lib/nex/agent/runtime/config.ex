defmodule Nex.Agent.Runtime.Config do
  @moduledoc """
  Configuration management for the runtime config contract.
  """

  alias Nex.Agent.Interface.Channel.Catalog, as: ChannelCatalog
  alias Nex.Agent.Sandbox.Policy
  alias Nex.Agent.Turn.LLM.ProviderProfile
  alias Nex.Agent.Turn.LLM.ProviderRegistry

  @default_config_path Path.join(System.get_env("HOME", "~"), ".nex/agent/config.json")
  @workbench_app_id_re ~r/^[a-z][a-z0-9_-]{1,63}$/

  defstruct max_iterations: 40,
            workspace: nil,
            channel: %{},
            gateway: %{},
            provider: %{},
            model: %{},
            subagents: %{},
            tools: %{},
            plugins: %{}

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
          tools: map(),
          plugins: map()
        }

  @type channel_diagnostic :: %{
          required(:code) => atom(),
          required(:instance_id) => String.t(),
          required(:type) => String.t() | nil,
          optional(:field) => String.t(),
          required(:message) => String.t()
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
      "tools" => config.tools,
      "plugins" => config.plugins
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
      tools: %{},
      plugins: default_plugins()
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
      tools: normalize_tools(Map.get(data, "tools")),
      plugins: normalize_plugins(Map.get(data, "plugins"))
    }
  end

  @spec model_role(t(), atom() | String.t(), keyword()) :: model_runtime() | nil
  def model_role(%__MODULE__{} = config, role, opts \\ []) when is_list(opts) do
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
         {:ok, runtime} <- resolve_model_runtime(config, model_key, opts) do
      runtime
    else
      _ -> nil
    end
  end

  @spec default_model_runtime(t(), keyword()) :: model_runtime() | nil
  def default_model_runtime(%__MODULE__{} = config, opts \\ []) when is_list(opts),
    do: model_role(config, :default, opts)

  @spec cheap_model_runtime(t(), keyword()) :: model_runtime() | nil
  def cheap_model_runtime(%__MODULE__{} = config, opts \\ []) when is_list(opts),
    do: model_role(config, :cheap, opts)

  @spec memory_model_runtime(t(), keyword()) :: model_runtime() | nil
  def memory_model_runtime(%__MODULE__{} = config, opts \\ []) when is_list(opts) do
    model_role(config, :memory, opts) || cheap_model_runtime(config, opts) ||
      default_model_runtime(config, opts)
  end

  @spec advisor_model_runtime(t(), keyword()) :: model_runtime() | nil
  def advisor_model_runtime(%__MODULE__{} = config, opts \\ []) when is_list(opts),
    do: model_role(config, :advisor, opts)

  @spec model_runtime(t(), String.t(), keyword()) ::
          {:ok, model_runtime()} | {:error, :unknown_model}
  def model_runtime(%__MODULE__{} = config, model_key, opts \\ [])
      when is_binary(model_key) and is_list(opts) do
    resolve_model_runtime(config, model_key, opts)
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

  @spec channel_runtime(t(), String.t() | atom(), keyword()) ::
          {:ok, map()} | {:error, channel_diagnostic()}
  def channel_runtime(%__MODULE__{} = config, instance_id, opts \\ []) when is_list(opts) do
    instance_id = to_string(instance_id)
    catalog_opts = catalog_opts(config, opts)

    with %{} = instance <- channel_instance(config, instance_id),
         {:ok, spec} <- ChannelCatalog.fetch(Map.get(instance, "type"), catalog_opts),
         normalized = spec.apply_defaults(instance),
         :ok <- spec.validate_instance(normalized, instance_id: instance_id, mode: :runtime) do
      {:ok, spec.runtime(normalized)}
    else
      nil ->
        {:error,
         channel_diagnostic(:unknown_channel_instance, instance_id, nil,
           message: "channel instance #{instance_id} is not configured"
         )}

      {:error, {:unknown_channel_type, type}} ->
        {:error,
         channel_diagnostic(:unknown_channel_type, instance_id, blank_to_nil(type),
           message: "channel type #{inspect(blank_to_nil(type))} is not supported"
         )}

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, normalize_channel_diagnostic(List.first(diagnostics), instance_id)}
    end
  end

  @spec channels_runtime(t(), keyword()) :: %{optional(String.t()) => map()}
  def channels_runtime(%__MODULE__{} = config, opts \\ []) when is_list(opts) do
    config
    |> channel_instances()
    |> Enum.reduce(%{}, fn {id, _instance}, acc ->
      case channel_runtime(config, id, opts) do
        {:ok, runtime} -> Map.put(acc, id, runtime)
        {:error, _diagnostic} -> acc
      end
    end)
  end

  @spec channel_diagnostics(t(), keyword()) :: [channel_diagnostic()]
  def channel_diagnostics(%__MODULE__{} = config, opts \\ []) when is_list(opts) do
    config
    |> channel_instances()
    |> Enum.flat_map(fn {id, instance} ->
      channel_instance_diagnostics(config, id, instance, opts)
    end)
  end

  @spec channel_streaming?(t(), String.t() | atom(), keyword()) :: boolean()
  def channel_streaming?(%__MODULE__{} = config, instance_id, opts \\ []) when is_list(opts) do
    case channel_runtime(config, instance_id, opts) do
      {:ok, runtime} -> Map.get(runtime, "streaming", false) == true
      {:error, _diagnostic} -> false
    end
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

  @spec plugins_runtime(t()) :: map()
  def plugins_runtime(%__MODULE__{plugins: plugins}) when is_map(plugins), do: plugins
  def plugins_runtime(_config), do: default_plugins()

  @spec file_access_allowed_roots(t() | nil) :: [String.t()]
  def file_access_allowed_roots(%__MODULE__{tools: tools}) when is_map(tools) do
    tools
    |> Map.get("file_access", %{})
    |> normalize_file_access_config()
    |> Map.get("allowed_roots", [])
  end

  def file_access_allowed_roots(_config), do: []

  @spec sandbox_runtime(t() | nil, keyword()) :: Policy.t()
  def sandbox_runtime(config, opts \\ [])

  def sandbox_runtime(%__MODULE__{} = config, opts) when is_list(opts) do
    sandbox =
      config.tools
      |> Map.get("sandbox", %{})
      |> normalize_sandbox_config()

    mode = sandbox_mode(Map.get(sandbox, "default_profile"))
    protected_paths = sandbox_protected_paths(sandbox)
    protected_names = normalize_string_list(Map.get(sandbox, "protected_names"))
    env_allowlist = normalize_string_list(Map.get(sandbox, "env_allowlist"))

    filesystem =
      mode
      |> sandbox_filesystem_defaults(Keyword.get(opts, :workspace))
      |> prepend_path_entries(:none, protected_paths)
      |> append_path_entries(:read, Map.get(sandbox, "allow_read_roots", []))
      |> append_path_entries(
        :write,
        file_access_allowed_roots(config) ++ Map.get(sandbox, "allow_write_roots", [])
      )
      |> append_path_entries(:none, Map.get(sandbox, "deny_read", []))
      |> append_path_entries(:none, Map.get(sandbox, "deny_write", []))
      |> uniq_filesystem_entries()

    %Policy{
      enabled: Map.get(sandbox, "enabled", true),
      backend: sandbox_backend(Map.get(sandbox, "backend")),
      mode: mode,
      network: sandbox_network(Map.get(sandbox, "network")),
      filesystem: filesystem,
      protected_paths: protected_paths,
      protected_names: default_if_empty(protected_names, Policy.default_protected_names()),
      env_allowlist: default_if_empty(env_allowlist, Policy.default_env_allowlist()),
      raw: sandbox
    }
  end

  def sandbox_runtime(_config, opts) when is_list(opts), do: sandbox_runtime(default(), opts)

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
    valid_new_shape?(config) and valid_providers?(config) and valid_default_model?(config) and
      valid_channels?(config)
  end

  @spec provider_diagnostics(t(), keyword()) :: [map()]
  def provider_diagnostics(%__MODULE__{} = config, opts \\ []) when is_list(opts) do
    registry_opts = catalog_opts(config, opts)

    config
    |> provider_entries()
    |> Enum.flat_map(fn {provider_key, provider_config} ->
      provider_type = Map.get(provider_config, "type")

      cond do
        is_nil(provider_type) ->
          [
            provider_diagnostic(
              :missing_provider_type,
              provider_key,
              nil,
              "provider #{provider_key} is missing a type"
            )
          ]

        is_nil(ProviderRegistry.provider_atom(provider_type)) ->
          [
            provider_diagnostic(
              :unknown_provider_type,
              provider_key,
              provider_type,
              "provider type #{inspect(provider_type)} is not supported"
            )
          ]

        not ProviderRegistry.provider_available?(provider_type, registry_opts) ->
          [
            provider_diagnostic(
              :disabled_provider_type,
              provider_key,
              provider_type,
              "provider type #{inspect(provider_type)} is disabled by plugin configuration"
            )
          ]

        true ->
          []
      end
    end)
  end

  @spec provider_type_to_atom(String.t() | atom() | nil) :: atom() | nil
  def provider_type_to_atom(type) when is_atom(type), do: type
  def provider_type_to_atom(type) when is_binary(type), do: ProviderRegistry.provider_atom(type)
  def provider_type_to_atom(_type), do: nil

  defp invalid do
    %__MODULE__{
      max_iterations: nil,
      workspace: nil,
      channel: %{},
      gateway: %{},
      provider: %{},
      model: %{},
      subagents: %{},
      tools: %{},
      plugins: default_plugins()
    }
  end

  defp resolve_model_runtime(%__MODULE__{} = config, model_key, opts) do
    models = Map.get(config.model || %{}, "models", %{})
    model_config = Map.get(models, model_key)
    registry_opts = catalog_opts(config, opts)

    with %{} <- model_config,
         provider_key when is_binary(provider_key) and provider_key != "" <-
           Map.get(model_config, "provider"),
         provider_config when is_map(provider_config) <-
           get_in(config.provider || %{}, ["providers", provider_key]),
         provider_type = Map.get(provider_config, "type", "openai-compatible"),
         true <- ProviderRegistry.provider_available?(provider_type, registry_opts),
         provider when is_atom(provider) <- provider_type_to_atom(provider_type) do
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
      is_map(config.model) and is_map(config.subagents) and is_map(config.tools) and
      is_map(config.plugins)
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
    channel_diagnostics(config) == []
  end

  defp valid_providers?(%__MODULE__{} = config) do
    provider_diagnostics(config) == []
  end

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
    type = normalize_optional_string(Map.get(instance, "type"))

    normalized =
      instance
      |> Map.put("type", type)
      |> Map.put("enabled", Map.get(instance, "enabled", false) == true)
      |> normalize_channel_secrets(type)

    case ChannelCatalog.fetch(type) do
      {:ok, spec} -> spec.apply_defaults(normalized)
      {:error, _reason} -> normalized
    end
  end

  defp normalize_channel_instance(_instance), do: nil

  defp normalize_channel_secrets(instance, type) do
    type
    |> channel_secret_fields()
    |> Enum.reduce(instance, fn key, acc ->
      case Map.get(acc, key) do
        %{} = secret -> Map.put(acc, key, resolve_secret(secret))
        _ -> acc
      end
    end)
  end

  defp channel_secret_fields(type) do
    case ChannelCatalog.fetch(type) do
      {:ok, spec} -> get_in(spec.config_contract(), ["secret_fields"]) || []
      {:error, _reason} -> []
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

  defp normalize_plugins(%{} = plugins) do
    plugins = stringify_map_keys(plugins)

    %{
      "disabled" => normalize_plugin_id_list(Map.get(plugins, "disabled")),
      "enabled" => normalize_enabled_plugins(Map.get(plugins, "enabled"))
    }
  end

  defp normalize_plugins(_plugins), do: default_plugins()

  defp normalize_plugin_id_list(ids) when is_list(ids) do
    ids
    |> Enum.map(&normalize_plugin_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_plugin_id_list(_ids), do: []

  defp normalize_enabled_plugins(%{} = enabled) do
    enabled
    |> stringify_map_keys()
    |> Enum.reduce(%{}, fn {id, value}, acc ->
      case normalize_plugin_id(id) do
        nil ->
          acc

        plugin_id ->
          if value in [true, "true"] do
            Map.put(acc, plugin_id, true)
          else
            acc
          end
      end
    end)
  end

  defp normalize_enabled_plugins(_enabled), do: %{}

  defp normalize_plugin_id(id) when is_binary(id) do
    id = String.trim(id)

    if Regex.match?(~r/^(builtin|workspace|project):[a-z][a-z0-9_.-]{1,79}$/, id) do
      id
    end
  end

  defp normalize_plugin_id(_id), do: nil

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
    type = normalize_optional_string(Map.get(config, "type")) || "openai-compatible"

    config
    |> Map.put("type", type)
    |> Map.update("api_key", nil, &normalize_secret_spec/1)
    |> Map.update("base_url", nil, &normalize_optional_string/1)
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

    tools
    |> maybe_normalize_tool_section("file_access", &normalize_file_access_config/1)
    |> maybe_normalize_tool_section("sandbox", &normalize_sandbox_config/1)
  end

  defp normalize_tools(_tools), do: %{}

  defp maybe_normalize_tool_section(tools, key, normalizer) do
    case Map.fetch(tools, key) do
      {:ok, config} -> Map.put(tools, key, normalizer.(config))
      :error -> tools
    end
  end

  defp normalize_file_access_config(%{} = config) do
    config = stringify_map_keys(config)

    %{
      "allowed_roots" => normalize_allowed_roots(Map.get(config, "allowed_roots"))
    }
  end

  defp normalize_file_access_config(_config), do: %{"allowed_roots" => []}

  defp normalize_sandbox_config(%{} = config) do
    config = stringify_map_keys(config)

    %{
      "enabled" => normalize_boolean(Map.get(config, "enabled"), true),
      "backend" => normalize_sandbox_backend(Map.get(config, "backend")),
      "default_profile" =>
        normalize_sandbox_profile(Map.get(config, "default_profile") || Map.get(config, "mode")),
      "network" => normalize_sandbox_network(Map.get(config, "network")),
      "allow_read_roots" => normalize_allowed_roots(Map.get(config, "allow_read_roots")),
      "allow_write_roots" => normalize_allowed_roots(Map.get(config, "allow_write_roots")),
      "deny_read" => normalize_allowed_roots(Map.get(config, "deny_read")),
      "deny_write" => normalize_allowed_roots(Map.get(config, "deny_write")),
      "protected_paths" => normalize_allowed_roots(Map.get(config, "protected_paths")),
      "protected_names" => normalize_string_list(Map.get(config, "protected_names")),
      "env_allowlist" => normalize_string_list(Map.get(config, "env_allowlist")),
      "auto_allow_sandboxed_bash" =>
        normalize_boolean(Map.get(config, "auto_allow_sandboxed_bash"), false),
      "approval" => normalize_sandbox_approval(Map.get(config, "approval"))
    }
  end

  defp normalize_sandbox_config(_config) do
    %{
      "enabled" => true,
      "backend" => "auto",
      "default_profile" => "workspace_write",
      "network" => "restricted",
      "allow_read_roots" => [],
      "allow_write_roots" => [],
      "deny_read" => [],
      "deny_write" => [],
      "protected_paths" => [],
      "protected_names" => [],
      "env_allowlist" => [],
      "auto_allow_sandboxed_bash" => false,
      "approval" => normalize_sandbox_approval(nil)
    }
  end

  defp normalize_allowed_roots(roots) when is_list(roots) do
    roots
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp normalize_allowed_roots(_roots), do: []

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(_values), do: []

  defp normalize_boolean(value, _default) when value in [true, "true", "TRUE", "1", 1],
    do: true

  defp normalize_boolean(value, _default) when value in [false, "false", "FALSE", "0", 0],
    do: false

  defp normalize_boolean(_value, default), do: default

  defp normalize_sandbox_backend(value) do
    case normalize_optional_string(value) do
      "seatbelt" -> "seatbelt"
      "macos" -> "seatbelt"
      "linux" -> "linux"
      "windows" -> "windows"
      "noop" -> "noop"
      _ -> "auto"
    end
  end

  defp normalize_sandbox_profile(value) do
    case normalize_optional_string(value) do
      "read_only" -> "read_only"
      "read-only" -> "read_only"
      "readonly" -> "read_only"
      "workspace_write" -> "workspace_write"
      "workspace-write" -> "workspace_write"
      "danger_full_access" -> "danger_full_access"
      "danger-full-access" -> "danger_full_access"
      "external" -> "external"
      _ -> "workspace_write"
    end
  end

  defp normalize_sandbox_network(value) do
    case normalize_optional_string(value) do
      "enabled" -> "enabled"
      "true" -> "enabled"
      "restricted" -> "restricted"
      "false" -> "restricted"
      _ -> "restricted"
    end
  end

  defp normalize_sandbox_approval(%{} = approval) do
    approval = stringify_map_keys(approval)

    %{
      "default" => normalize_sandbox_approval_default(Map.get(approval, "default")),
      "allow_session_grants" =>
        normalize_boolean(Map.get(approval, "allow_session_grants"), true),
      "allow_always_grants" => normalize_boolean(Map.get(approval, "allow_always_grants"), true)
    }
  end

  defp normalize_sandbox_approval(_approval) do
    %{
      "default" => "ask",
      "allow_session_grants" => true,
      "allow_always_grants" => true
    }
  end

  defp normalize_sandbox_approval_default(value) do
    case normalize_optional_string(value) do
      "ask" -> "ask"
      "deny" -> "deny"
      "allow" -> "allow"
      _ -> "ask"
    end
  end

  defp sandbox_backend("seatbelt"), do: :seatbelt
  defp sandbox_backend("linux"), do: :linux
  defp sandbox_backend("windows"), do: :windows
  defp sandbox_backend("noop"), do: :noop
  defp sandbox_backend(_backend), do: :auto

  defp sandbox_mode("read_only"), do: :read_only
  defp sandbox_mode("danger_full_access"), do: :danger_full_access
  defp sandbox_mode("external"), do: :external
  defp sandbox_mode(_profile), do: :workspace_write

  defp sandbox_network("enabled"), do: :enabled
  defp sandbox_network(_network), do: :restricted

  defp sandbox_protected_paths(sandbox) do
    (default_protected_paths() ++ Map.get(sandbox, "protected_paths", []))
    |> Enum.uniq()
  end

  defp default_protected_paths do
    [
      Path.expand("~/.zshrc"),
      Path.expand("~/.nex/agent/config.json")
    ]
  end

  defp sandbox_filesystem_defaults(:danger_full_access, _workspace), do: []

  defp sandbox_filesystem_defaults(:read_only, _workspace) do
    [
      %{path: {:special, :minimal}, access: :read},
      %{path: {:special, :workspace}, access: :read}
    ]
  end

  defp sandbox_filesystem_defaults(:external, _workspace) do
    [
      %{path: {:special, :minimal}, access: :read}
    ]
  end

  defp sandbox_filesystem_defaults(_mode, _workspace) do
    [
      %{path: {:special, :minimal}, access: :read},
      %{path: {:special, :workspace}, access: :write},
      %{path: {:special, :tmp}, access: :write},
      %{path: {:special, :slash_tmp}, access: :write}
    ]
  end

  defp prepend_path_entries(entries, access, paths) do
    path_entries(paths, access) ++ entries
  end

  defp append_path_entries(entries, access, paths) do
    entries ++ path_entries(paths, access)
  end

  defp path_entries(paths, access) do
    paths
    |> normalize_allowed_roots()
    |> Enum.map(&%{path: {:path, &1}, access: access})
  end

  defp uniq_filesystem_entries(entries) do
    entries
    |> Enum.reduce({[], MapSet.new()}, fn entry, {acc, seen} ->
      key = {entry.path, entry.access}

      if MapSet.member?(seen, key) do
        {acc, seen}
      else
        {[entry | acc], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp default_if_empty([], default), do: default
  defp default_if_empty(value, _default), do: value

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

  defp default_plugins, do: %{"disabled" => [], "enabled" => %{}}

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

  defp provider_entries(%__MODULE__{} = config) do
    case config.provider do
      %{} = provider ->
        case Map.get(provider, "providers", %{}) do
          %{} = providers -> providers
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp provider_diagnostic(code, provider_key, type, message) do
    %{
      code: code,
      provider_key: provider_key,
      type: type,
      message: message
    }
  end

  defp channel_instance_diagnostics(%__MODULE__{} = config, instance_id, %{} = instance, opts) do
    case ChannelCatalog.fetch(Map.get(instance, "type"), catalog_opts(config, opts)) do
      {:ok, spec} ->
        normalized = spec.apply_defaults(instance)

        case spec.validate_instance(normalized, instance_id: instance_id, mode: :runtime) do
          :ok ->
            []

          {:error, diagnostics} when is_list(diagnostics) ->
            Enum.map(diagnostics, &normalize_channel_diagnostic(&1, instance_id))
        end

      {:error, {:unknown_channel_type, type}} ->
        [
          channel_diagnostic(:unknown_channel_type, instance_id, blank_to_nil(type),
            message: "channel type #{inspect(blank_to_nil(type))} is not supported"
          )
        ]
    end
  end

  defp catalog_opts(%__MODULE__{} = config, opts) when is_list(opts) do
    Keyword.put_new(opts, :config, config)
  end

  defp normalize_channel_diagnostic(%{} = diagnostic, instance_id) do
    channel_diagnostic(
      Map.get(diagnostic, :code, :invalid_channel_instance),
      Map.get(diagnostic, :instance_id) || instance_id,
      Map.get(diagnostic, :type),
      field: Map.get(diagnostic, :field),
      message: Map.get(diagnostic, :message, "channel instance is invalid")
    )
  end

  defp channel_diagnostic(code, instance_id, type, opts) do
    diagnostic = %{
      code: code,
      instance_id: to_string(instance_id),
      type: type,
      message: Keyword.fetch!(opts, :message)
    }

    case Keyword.get(opts, :field) do
      nil -> diagnostic
      field -> Map.put(diagnostic, :field, field)
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
