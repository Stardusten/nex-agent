defmodule Nex.Agent.Interface.Workbench.ConfigPanel do
  @moduledoc false

  require Nex.Agent.Observe.ControlPlane.Log

  alias Nex.Agent.Interface.Channel.Catalog, as: ChannelCatalog
  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Turn.LLM.ProviderRegistry
  alias Nex.Agent.Runtime
  alias Nex.Agent.Runtime.Snapshot

  @context_strategies ~w(server_side server_side_then_recent provider_native provider_native_then_recent native native_compaction)
  @role_keys ~w(default_model cheap_model memory_model advisor_model)
  @provider_reserved_keys ~w(type api_key base_url)
  @model_reserved_keys ~w(provider id context_window context_tokens max_context_tokens context_limit model_context_window auto_compact_token_limit model_auto_compact_token_limit context_strategy)
  @secret_placeholder "******"
  @key_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,119}$/
  @env_regex ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @provider_type_guides %{
    "openai-compatible" => %{
      "label" => "OpenAI-compatible",
      "summary" =>
        "Chat Completions compatible endpoint for DeepSeek, Kimi, Tencent Hunyuan, and internal OpenAI-style proxies.",
      "best_for" => "Most third-party hosted models.",
      "requires" => ["base_url", "api_key or env var"]
    },
    "openai" => %{
      "label" => "OpenAI",
      "summary" => "First-party OpenAI-style provider using the standard OpenAI API key path.",
      "best_for" => "Standard OpenAI API models.",
      "requires" => ["api_key or OPENAI_API_KEY", "optional base_url override"]
    },
    "anthropic" => %{
      "label" => "Anthropic",
      "summary" => "Native Anthropic provider for Claude-family models.",
      "best_for" => "Claude models through Anthropic-compatible credentials.",
      "requires" => ["api_key or ANTHROPIC_API_KEY", "optional base_url override"]
    },
    "openai-codex" => %{
      "label" => "OpenAI Codex",
      "summary" =>
        "Codex Responses adapter that can use the local Codex OAuth token and default Codex backend.",
      "best_for" =>
        "Coding-oriented Codex models when this machine already has Codex auth available.",
      "requires" => ["usually no api_key", "optional base_url override switches to api-key mode"]
    },
    "openai-codex-custom" => %{
      "label" => "OpenAI Codex Custom",
      "summary" => "Codex-compatible Responses adapter for explicit API-key based endpoints.",
      "best_for" =>
        "Custom Codex-compatible gateways or hosted OpenAI Responses-compatible endpoints.",
      "requires" => ["base_url", "api_key or env var"]
    },
    "openrouter" => %{
      "label" => "OpenRouter",
      "summary" => "OpenRouter provider with model IDs like provider/model-name.",
      "best_for" => "Routing many hosted model families behind one credential.",
      "requires" => ["api_key or env var", "optional base_url override"]
    },
    "ollama" => %{
      "label" => "Ollama",
      "summary" => "Local Ollama endpoint exposed through its OpenAI-compatible /v1 API.",
      "best_for" => "Local models and offline experiments.",
      "requires" => ["base_url", "no real api_key"]
    }
  }

  @context_strategy_guides %{
    "" => %{
      "label" => "Default",
      "summary" =>
        "No explicit context strategy; Nex uses the model context window when configured, otherwise the normal recent-message limit."
    },
    "server_side" => %{
      "label" => "Server-side",
      "summary" =>
        "Keep context budgeting on the Nex side. This is the safest explicit setting for ordinary providers."
    },
    "server_side_then_recent" => %{
      "label" => "Server-side then recent",
      "summary" =>
        "Use Nex context budgeting while preserving a recent tail after compaction-capable turns."
    },
    "provider_native" => %{
      "label" => "Provider native",
      "summary" => "Use provider-native context handling where the selected provider supports it."
    },
    "provider_native_then_recent" => %{
      "label" => "Provider native then recent",
      "summary" => "Use provider-native context handling with Nex recent-history fallback."
    },
    "native" => %{
      "label" => "Native",
      "summary" => "Short alias for provider-native context handling on capable providers."
    },
    "native_compaction" => %{
      "label" => "Native compaction",
      "summary" => "Ask compaction-capable providers to emit and reuse native compaction items."
    }
  }

  @spec overview(Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def overview(%Snapshot{} = snapshot) do
    with {:ok, raw} <- read_raw_config(snapshot) do
      {:ok, %{"config" => config_view(raw, snapshot)}}
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @spec upsert_provider(String.t(), map(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def upsert_provider(provider_key, attrs, %Snapshot{} = snapshot) when is_map(attrs) do
    update_config(snapshot, "provider", provider_key, fn raw ->
      with {:ok, key} <- normalize_key(provider_key, "provider"),
           provider_root = map_at(raw, "provider"),
           providers = map_at(provider_root, "providers"),
           existing = map_at(providers, key),
           {:ok, type} <-
             provider_type(Map.get(attrs, "type") || Map.get(existing, "type"), snapshot),
           {:ok, api_key} <- secret_update(Map.get(existing, "api_key"), "api_key", attrs) do
        options =
          existing
          |> Map.drop(@provider_reserved_keys)
          |> Map.merge(clean_options(Map.get(attrs, "options")))

        entry =
          options
          |> Map.put("type", type)
          |> Map.put("api_key", api_key)
          |> Map.put(
            "base_url",
            normalize_optional_string(Map.get(attrs, "base_url")) || Map.get(existing, "base_url")
          )

        providers = Map.put(providers, key, entry)
        {:ok, put_provider_entries(raw, providers)}
      end
    end)
  end

  @spec delete_provider(String.t(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def delete_provider(provider_key, %Snapshot{} = snapshot) do
    update_config(snapshot, "provider", provider_key, fn raw ->
      with {:ok, key} <- normalize_key(provider_key, "provider") do
        models = raw |> model_entries()

        used_by =
          models
          |> Enum.filter(fn {_model_key, model} -> Map.get(model, "provider") == key end)
          |> Enum.map(fn {model_key, _model} -> model_key end)

        if used_by == [] do
          providers =
            raw
            |> provider_entries()
            |> Map.delete(key)

          {:ok, put_provider_entries(raw, providers)}
        else
          {:error, "provider #{key} is still used by models: #{Enum.join(used_by, ", ")}"}
        end
      end
    end)
  end

  @spec upsert_model(String.t(), map(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def upsert_model(model_key, attrs, %Snapshot{} = snapshot) when is_map(attrs) do
    update_config(snapshot, "model", model_key, fn raw ->
      with {:ok, key} <- normalize_key(model_key, "model"),
           models = model_entries(raw),
           existing = map_at(models, key),
           provider =
             normalize_optional_string(Map.get(attrs, "provider")) ||
               Map.get(existing, "provider"),
           :ok <- require_existing_provider(raw, provider),
           {:ok, entry} <- model_entry(key, existing, attrs) do
        {:ok, put_model_entries(raw, Map.put(models, key, entry))}
      end
    end)
  end

  @spec delete_model(String.t(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def delete_model(model_key, %Snapshot{} = snapshot) do
    update_config(snapshot, "model", model_key, fn raw ->
      with {:ok, key} <- normalize_key(model_key, "model") do
        model_root = map_at(raw, "model")

        used_by =
          @role_keys
          |> Enum.filter(&(Map.get(model_root, &1) == key))

        if used_by == [] do
          {:ok, put_model_entries(raw, raw |> model_entries() |> Map.delete(key))}
        else
          {:error, "model #{key} is still assigned to roles: #{Enum.join(used_by, ", ")}"}
        end
      end
    end)
  end

  @spec update_model_roles(map(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def update_model_roles(attrs, %Snapshot{} = snapshot) when is_map(attrs) do
    update_config(snapshot, "model_roles", "roles", fn raw ->
      models = model_entries(raw)
      model_root = map_at(raw, "model")

      Enum.reduce_while(@role_keys, {:ok, model_root}, fn role, {:ok, acc} ->
        if Map.has_key?(attrs, role) do
          value = normalize_optional_string(Map.get(attrs, role))

          cond do
            role == "default_model" and is_nil(value) ->
              {:halt, {:error, "default_model is required"}}

            is_nil(value) ->
              {:cont, {:ok, Map.put(acc, role, nil)}}

            Map.has_key?(models, value) ->
              {:cont, {:ok, Map.put(acc, role, value)}}

            true ->
              {:halt, {:error, "#{role} references unknown model #{value}"}}
          end
        else
          {:cont, {:ok, acc}}
        end
      end)
      |> case do
        {:ok, next_model_root} -> {:ok, Map.put(raw, "model", next_model_root)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec upsert_channel(String.t(), map(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def upsert_channel(channel_id, attrs, %Snapshot{} = snapshot) when is_map(attrs) do
    update_config(snapshot, "channel", channel_id, fn raw ->
      with {:ok, key} <- normalize_key(channel_id, "channel"),
           channels = channel_entries(raw),
           existing = map_at(channels, key),
           {:ok, type} <-
             channel_type(Map.get(attrs, "type") || Map.get(existing, "type"), snapshot),
           {:ok, entry} <- channel_entry(type, existing, attrs, snapshot) do
        {:ok, Map.put(raw, "channel", Map.put(channels, key, entry))}
      end
    end)
  end

  @spec delete_channel(String.t(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def delete_channel(channel_id, %Snapshot{} = snapshot) do
    update_config(snapshot, "channel", channel_id, fn raw ->
      with {:ok, key} <- normalize_key(channel_id, "channel") do
        {:ok, Map.put(raw, "channel", raw |> channel_entries() |> Map.delete(key))}
      end
    end)
  end

  defp update_config(%Snapshot{} = snapshot, section, target, fun) do
    with {:ok, path} <- writable_config_path(snapshot),
         {:ok, raw} <- Config.read_map(config_path: path),
         {:ok, next_raw} <- fun.(raw),
         {:ok, next_config} <- validate_raw_config(next_raw, snapshot),
         :ok <- Config.save_map(next_raw, config_path: path) do
      case reload_runtime(snapshot, path) do
        {:ok, reload_status} ->
          log_config_update(snapshot, section, target, reload_status)

          {:ok,
           %{
             "config" => config_view(next_raw, %{snapshot | config: next_config}),
             "runtime_reload" => reload_status
           }}
      end
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp config_view(raw, %Snapshot{} = snapshot) do
    config = Config.from_map(raw)

    %{
      "config_path" => snapshot.config_path,
      "workspace" => config.workspace,
      "max_iterations" => config.max_iterations,
      "provider_types" => provider_types(snapshot),
      "provider_type_guides" => provider_type_guides(snapshot),
      "channel_types" => ChannelCatalog.types(plugin_catalog_opts(snapshot)),
      "channel_type_guides" => channel_type_guides(snapshot),
      "discord_table_modes" => channel_option_values(snapshot, "discord", "show_table_as"),
      "context_strategies" => @context_strategies,
      "context_strategy_guides" => @context_strategy_guides,
      "providers" => provider_views(raw),
      "models" => model_views(raw),
      "model_roles" => model_roles(raw),
      "channels" => channel_views(raw, config, snapshot)
    }
  end

  defp provider_views(raw) do
    raw
    |> provider_entries()
    |> Enum.sort_by(fn {key, _entry} -> key end)
    |> Enum.map(fn {key, entry} ->
      %{
        "key" => key,
        "type" => Map.get(entry, "type"),
        "base_url" => Map.get(entry, "base_url"),
        "api_key" => secret_view(Map.get(entry, "api_key")),
        "options" => Map.drop(entry, @provider_reserved_keys)
      }
    end)
  end

  defp model_views(raw) do
    raw
    |> model_entries()
    |> Enum.sort_by(fn {key, _entry} -> key end)
    |> Enum.map(fn {key, entry} ->
      %{
        "key" => key,
        "provider" => Map.get(entry, "provider"),
        "id" => Map.get(entry, "id") || key,
        "context_window" => Map.get(entry, "context_window"),
        "auto_compact_token_limit" => Map.get(entry, "auto_compact_token_limit"),
        "context_strategy" => Map.get(entry, "context_strategy"),
        "options" => Map.drop(entry, @model_reserved_keys)
      }
    end)
  end

  defp model_roles(raw) do
    root = map_at(raw, "model")
    Map.take(root, @role_keys)
  end

  defp channel_views(raw, %Config{} = config, %Snapshot{} = snapshot) do
    raw
    |> channel_entries()
    |> Enum.sort_by(fn {key, _entry} -> key end)
    |> Enum.map(fn {key, entry} ->
      runtime =
        case Config.channel_runtime(config, key, plugin_catalog_opts(snapshot)) do
          {:ok, runtime} -> runtime
          {:error, _diagnostic} -> %{}
        end

      type = Map.get(entry, "type") || Map.get(runtime, "type")
      contract = channel_contract(snapshot, type)
      desired = channel_desired_entry(snapshot, type, entry)
      secret_fields = contract_field(contract, "secret_fields")
      fields = contract_field(contract, "fields")

      base = %{
        "id" => key,
        "type" => type,
        "enabled" => Map.get(entry, "enabled", false) == true,
        "streaming" => Map.get(desired, "streaming", false) == true,
        "app_id" => Map.get(entry, "app_id"),
        "guild_id" => Map.get(entry, "guild_id"),
        "allow_from" => list_value(Map.get(entry, "allow_from")),
        "show_table_as" => Map.get(desired, "show_table_as"),
        "settings" =>
          Map.drop(
            entry,
            secret_fields ++
              fields ++ ~w(type enabled streaming app_id guild_id allow_from show_table_as)
          )
      }

      secret_views =
        Map.new(secret_fields, fn field -> {field, secret_view(Map.get(entry, field))} end)

      Map.merge(base, secret_views)
    end)
  end

  defp model_entry(key, existing, attrs) do
    provider =
      normalize_optional_string(Map.get(attrs, "provider")) || Map.get(existing, "provider")

    id = normalize_optional_string(Map.get(attrs, "id")) || Map.get(existing, "id") || key

    existing
    |> Map.drop(@model_reserved_keys)
    |> Map.merge(clean_options(Map.get(attrs, "options")))
    |> Map.put("provider", provider)
    |> Map.put("id", id)
    |> maybe_put_positive(attrs, "context_window")
    |> maybe_put_positive(attrs, "auto_compact_token_limit")
    |> maybe_put_context_strategy(attrs)
  end

  defp channel_entry(type, existing, attrs, %Snapshot{} = snapshot) do
    spec = ChannelCatalog.fetch!(type, plugin_catalog_opts(snapshot))
    contract = spec.config_contract()

    base =
      if Map.get(existing, "type") == type do
        existing
      else
        %{}
      end

    with {:ok, base} <- maybe_put_secrets(base, attrs, contract_field(contract, "secret_fields")) do
      entry =
        base
        |> Map.put("type", type)
        |> Map.put(
          "enabled",
          boolean_value(Map.get(attrs, "enabled"), Map.get(base, "enabled", false))
        )
        |> Map.put(
          "streaming",
          boolean_value(
            Map.get(attrs, "streaming"),
            Map.get(base, "streaming", get_in(contract, ["defaults", "streaming"]) == true)
          )
        )
        |> maybe_put_string_value(attrs, "app_id")
        |> maybe_put_string_value(attrs, "guild_id")
        |> maybe_put_allow_from(attrs)
        |> apply_channel_options(attrs, base, contract)
        |> prune_channel_fields(contract)

      require_enabled_channel_contract(entry, contract)
    end
  end

  defp maybe_put_secrets(entry, attrs, fields) do
    Enum.reduce_while(fields, {:ok, entry}, fn field, {:ok, acc} ->
      case maybe_put_secret(acc, attrs, field) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp maybe_put_secret(entry, attrs, field) do
    with {:ok, value} <- secret_update(Map.get(entry, field), field, attrs) do
      {:ok, Map.put(entry, field, value)}
    end
  end

  defp secret_update(existing, field, attrs) do
    mode =
      attrs
      |> Map.get("#{field}_mode", "keep")
      |> normalize_optional_string()
      |> case do
        nil -> "keep"
        value -> value
      end

    case mode do
      "keep" ->
        {:ok, existing}

      "none" ->
        {:ok, nil}

      "env" ->
        env = normalize_optional_string(Map.get(attrs, "#{field}_env"))

        cond do
          is_nil(env) -> {:error, "#{field} env var is required"}
          Regex.match?(@env_regex, env) -> {:ok, %{"env" => env}}
          true -> {:error, "#{field} env var is invalid"}
        end

      "literal" ->
        case normalize_optional_string(Map.get(attrs, "#{field}_value")) do
          nil -> {:error, "#{field} value is required"}
          value -> {:ok, value}
        end

      _ ->
        {:error, "#{field} mode #{mode} is not supported"}
    end
  end

  defp maybe_put_positive({:ok, entry}, attrs, key), do: maybe_put_positive(entry, attrs, key)

  defp maybe_put_positive(entry, attrs, key) when is_map(entry) do
    if Map.has_key?(attrs, key) do
      case positive_integer_or_nil(Map.get(attrs, key)) do
        {:ok, nil} -> {:ok, Map.delete(entry, key)}
        {:ok, value} -> {:ok, Map.put(entry, key, value)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, entry}
    end
  end

  defp maybe_put_context_strategy({:ok, entry}, attrs),
    do: maybe_put_context_strategy(entry, attrs)

  defp maybe_put_context_strategy(entry, attrs) when is_map(entry) do
    if Map.has_key?(attrs, "context_strategy") do
      case normalize_optional_string(Map.get(attrs, "context_strategy")) do
        nil ->
          {:ok, Map.delete(entry, "context_strategy")}

        value when value in @context_strategies ->
          {:ok, Map.put(entry, "context_strategy", value)}

        value ->
          {:error, "context_strategy #{inspect(value)} is not supported"}
      end
    else
      {:ok, entry}
    end
  end

  defp maybe_put_string_value(entry, attrs, key) do
    if Map.has_key?(attrs, key) do
      Map.put(entry, key, normalize_optional_string(Map.get(attrs, key)))
    else
      entry
    end
  end

  defp maybe_put_allow_from(entry, attrs) do
    if Map.has_key?(attrs, "allow_from") do
      Map.put(entry, "allow_from", list_value(Map.get(attrs, "allow_from")))
    else
      entry
    end
  end

  defp require_existing_provider(_raw, nil), do: {:error, "model provider is required"}

  defp require_existing_provider(raw, provider) do
    if Map.has_key?(provider_entries(raw), provider) do
      :ok
    else
      {:error, "model provider #{provider} does not exist"}
    end
  end

  defp provider_type(nil, _snapshot), do: {:error, "provider type is required"}

  defp provider_type(type, %Snapshot{} = snapshot) do
    type = normalize_optional_string(type)

    if type in provider_types(snapshot) do
      {:ok, type}
    else
      {:error, "provider type #{inspect(type)} is not supported"}
    end
  end

  defp channel_type(nil, _snapshot), do: {:error, "channel type is required"}

  defp channel_type(type, %Snapshot{} = snapshot) do
    type = normalize_optional_string(type)

    case ChannelCatalog.fetch(type, plugin_catalog_opts(snapshot)) do
      {:ok, spec} -> {:ok, spec.type()}
      {:error, _reason} -> {:error, "channel type #{inspect(type)} is not supported"}
    end
  end

  defp normalize_key(key, label) when is_binary(key) do
    key = String.trim(key)

    cond do
      key == "" -> {:error, "#{label} key is required"}
      String.contains?(key, "/") -> {:error, "#{label} key cannot contain /"}
      Regex.match?(@key_regex, key) -> {:ok, key}
      true -> {:error, "#{label} key #{inspect(key)} is invalid"}
    end
  end

  defp normalize_key(_key, label), do: {:error, "#{label} key is required"}

  defp provider_entries(raw), do: raw |> map_at("provider") |> map_at("providers")
  defp model_entries(raw), do: raw |> map_at("model") |> map_at("models")
  defp channel_entries(raw), do: map_at(raw, "channel")

  defp put_provider_entries(raw, providers) do
    provider_root =
      raw
      |> map_at("provider")
      |> Map.put("providers", providers)

    Map.put(raw, "provider", provider_root)
  end

  defp put_model_entries(raw, models) do
    model_root =
      raw
      |> map_at("model")
      |> Map.put("models", models)

    Map.put(raw, "model", model_root)
  end

  defp clean_options(%{} = options) do
    options
    |> stringify_map_keys()
    |> Enum.reject(fn {key, _value} ->
      key in @provider_reserved_keys or key in @model_reserved_keys
    end)
    |> Map.new()
  end

  defp clean_options(_options), do: %{}

  defp map_at(%{} = map, key) do
    case Map.get(map, key) do
      %{} = value -> stringify_map_keys(value)
      _ -> %{}
    end
  end

  defp map_at(_map, _key), do: %{}

  defp secret_view(%{"env" => env}) when is_binary(env) do
    %{"mode" => "env", "env" => env, "configured" => true, "display_value" => @secret_placeholder}
  end

  defp secret_view(%{env: env}) when is_binary(env), do: secret_view(%{"env" => env})

  defp secret_view(value) when is_binary(value) do
    configured = String.trim(value) != ""

    %{
      "mode" => "literal",
      "env" => nil,
      "configured" => configured,
      "display_value" => if(configured, do: @secret_placeholder)
    }
  end

  defp secret_view(_value),
    do: %{"mode" => "none", "env" => nil, "configured" => false, "display_value" => nil}

  defp positive_integer_or_nil(nil), do: {:ok, nil}
  defp positive_integer_or_nil(""), do: {:ok, nil}

  defp positive_integer_or_nil(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, "#{inspect(value)} must be a positive integer"}
    end
  end

  defp positive_integer_or_nil(_value), do: {:error, "value must be a positive integer"}

  defp boolean_value(value, default) when value in [nil, ""], do: default == true
  defp boolean_value(value, _default) when value in [true, "true", "1", "on"], do: true
  defp boolean_value(value, _default) when value in [false, "false", "0", "off"], do: false
  defp boolean_value(_value, default), do: default == true

  defp list_value(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp list_value(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> list_value()
  end

  defp list_value(_value), do: []

  defp read_raw_config(%Snapshot{} = snapshot) do
    case snapshot.config_path do
      path when is_binary(path) and path != "" -> Config.read_map(config_path: path)
      _ -> {:ok, Config.to_map(snapshot.config || Config.default())}
    end
  end

  defp writable_config_path(%Snapshot{config_path: path}) when is_binary(path) and path != "",
    do: {:ok, path}

  defp writable_config_path(_snapshot),
    do: {:error, "runtime snapshot does not expose a config path"}

  defp validate_raw_config(raw, %Snapshot{} = snapshot) do
    config = Config.from_map(raw)

    if Config.valid?(%{config | channel: %{}}) and raw_channels_valid?(raw, snapshot) do
      {:ok, config}
    else
      {:error, "config update would produce an invalid raw config"}
    end
  end

  defp raw_channels_valid?(raw, %Snapshot{} = snapshot) do
    raw
    |> channel_entries()
    |> Enum.all?(fn {_id, entry} -> raw_channel_valid?(entry, snapshot) end)
  end

  defp raw_channel_valid?(%{} = entry, %Snapshot{} = snapshot) do
    with {:ok, spec} <-
           ChannelCatalog.fetch(Map.get(entry, "type"), plugin_catalog_opts(snapshot)) do
      case require_enabled_channel_contract(entry, spec.config_contract()) do
        {:ok, _entry} -> true
        {:error, _reason} -> false
      end
    else
      {:error, _reason} -> false
    end
  end

  defp raw_channel_valid?(_entry, _snapshot), do: false

  defp require_enabled_channel_contract(%{"enabled" => true, "type" => type} = entry, contract) do
    missing =
      contract
      |> contract_field("required_when_enabled")
      |> Enum.find(&(not raw_present?(Map.get(entry, &1))))

    if is_nil(missing) do
      {:ok, entry}
    else
      {:error, "enabled #{type} channel requires #{missing}"}
    end
  end

  defp require_enabled_channel_contract(entry, _contract), do: {:ok, entry}

  defp raw_present?(%{"env" => env}) when is_binary(env), do: String.trim(env) != ""
  defp raw_present?(%{env: env}) when is_binary(env), do: String.trim(env) != ""
  defp raw_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp raw_present?(_value), do: false

  defp log_config_update(snapshot, section, target, reload_status) do
    _ =
      Nex.Agent.Observe.ControlPlane.Log.info(
        "workbench.config.updated",
        %{
          "section" => section,
          "target" => to_string(target),
          "runtime_reload_status" => Map.get(reload_status, "status")
        },
        workspace: snapshot.workspace,
        context: %{"channel" => "workbench", "session_key" => "workbench:configuration"}
      )

    :ok
  end

  defp reload_runtime(snapshot, config_path) do
    case Runtime.reload(
           workspace: snapshot.workspace,
           config_path: config_path,
           changed_paths: [config_path]
         ) do
      {:ok, reloaded} ->
        {:ok, %{"status" => "reloaded", "applied" => true, "version" => reloaded.version}}

      {:error, :runtime_unavailable} ->
        {:ok, %{"status" => "failed", "applied" => false, "reason" => "runtime_unavailable"}}

      {:error, reason} ->
        {:ok, %{"status" => "failed", "applied" => false, "reason" => format_error(reason)}}
    end
  end

  defp provider_types(%Snapshot{} = snapshot) do
    ProviderRegistry.known_provider_types(plugin_catalog_opts(snapshot))
  end

  defp provider_type_guides(%Snapshot{} = snapshot) do
    Map.take(@provider_type_guides, provider_types(snapshot))
  end

  defp plugin_catalog_opts(%Snapshot{} = snapshot) do
    if snapshot_plugins_empty?(snapshot.plugins) do
      [config: snapshot.config || Config.default()]
    else
      [plugin_data: snapshot.plugins]
    end
  end

  defp snapshot_plugins_empty?(%{contributions: contributions}) do
    Enum.all?(~w(channels providers tools skills commands), fn kind ->
      contributions
      |> contribution_values(kind)
      |> Enum.empty?()
    end)
  end

  defp snapshot_plugins_empty?(%{"contributions" => contributions}) do
    Enum.all?(~w(channels providers tools skills commands), fn kind ->
      contributions
      |> contribution_values(kind)
      |> Enum.empty?()
    end)
  end

  defp snapshot_plugins_empty?(_plugins), do: true

  defp contribution_values(contributions, kind) when is_map(contributions) do
    Map.get(contributions, kind) || Map.get(contributions, String.to_existing_atom(kind)) || []
  rescue
    ArgumentError -> []
  end

  defp contribution_values(_contributions, _kind), do: []

  defp channel_type_guides(%Snapshot{} = snapshot) do
    ChannelCatalog.all(plugin_catalog_opts(snapshot))
    |> Map.new(fn spec ->
      contract = spec.config_contract()
      ui = Map.get(contract, "ui", %{})

      {spec.type(),
       %{
         "label" => Map.get(contract, "label"),
         "summary" => Map.get(ui, "summary"),
         "requires" => Map.get(ui, "requires", [])
       }}
    end)
  end

  defp channel_option_values(%Snapshot{} = snapshot, type, field) do
    case channel_contract(snapshot, type) do
      %{} = contract -> get_in(contract, ["options", field]) || []
      nil -> []
    end
  end

  defp channel_contract(%Snapshot{} = snapshot, type) do
    with {:ok, spec} <- ChannelCatalog.fetch(type, plugin_catalog_opts(snapshot)) do
      spec.config_contract()
    else
      {:error, _reason} -> nil
    end
  end

  defp channel_desired_entry(%Snapshot{} = snapshot, type, %{} = entry) do
    with {:ok, spec} <- ChannelCatalog.fetch(type, plugin_catalog_opts(snapshot)) do
      spec.apply_defaults(entry)
    else
      {:error, _reason} -> entry
    end
  end

  defp contract_field(%{} = contract, field) do
    case Map.get(contract, field) do
      values when is_list(values) -> values
      _ -> []
    end
  end

  defp contract_field(_contract, _field), do: []

  defp apply_channel_options(entry, attrs, base, contract) do
    contract
    |> Map.get("options", %{})
    |> Enum.reduce(entry, fn {field, allowed}, acc ->
      default = get_in(contract, ["defaults", field])
      value = Map.get(attrs, field, Map.get(base, field, default))
      Map.put(acc, field, normalize_option_value(value, allowed, default))
    end)
  end

  defp normalize_option_value(value, allowed, default) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in allowed, do: normalized, else: default
  end

  defp normalize_option_value(value, allowed, default) do
    if value in allowed, do: value, else: default
  end

  defp prune_channel_fields(entry, contract) do
    fields = MapSet.new(contract_field(contract, "fields"))
    Map.filter(entry, fn {key, _value} -> MapSet.member?(fields, key) end)
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_nested(value)} end)
  end

  defp stringify_nested(%{} = value), do: stringify_map_keys(value)
  defp stringify_nested(value) when is_list(value), do: Enum.map(value, &stringify_nested/1)
  defp stringify_nested(value), do: value

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalize_optional_string(_value), do: nil

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
