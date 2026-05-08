defmodule Nex.Agent.SecretBase do
  @moduledoc """
  Minimal secret resolver boundary for plugin external-service integration.

  Secret plaintext is returned only to execution-boundary callers. Diagnostics
  and ControlPlane observations include the secret id/source shape, never the
  resolved value.
  """

  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Runtime.Config
  require Log

  @callback resolve(String.t(), map()) :: {:ok, String.t()} | {:error, term()}

  @spec resolve(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def resolve(secret_id, ctx) when is_binary(secret_id) and is_map(ctx) do
    secret_id = String.trim(secret_id)

    result =
      cond do
        secret_id == "" ->
          {:error, {:missing_secret, secret_id}}

        not is_nil(explicit_secret(ctx, secret_id)) ->
          resolve_spec(explicit_secret(ctx, secret_id), secret_id)

        true ->
          ctx
          |> config_secret(secret_id)
          |> resolve_spec(secret_id)
      end

    case result do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} = error ->
        emit_warning(secret_id, reason, ctx)
        error
    end
  end

  def resolve(secret_id, ctx) when is_map(ctx), do: resolve(to_string(secret_id), ctx)
  def resolve(secret_id, _ctx), do: resolve(to_string(secret_id), %{})

  defp explicit_secret(ctx, secret_id) do
    ctx
    |> get_key(:secrets)
    |> get_key(secret_id)
  end

  defp config_secret(ctx, secret_id) do
    config = get_key(ctx, :config)
    plugin_id = get_key(ctx, :plugin_id)

    secrets =
      case ctx |> get_key(:secret_specs) |> normalize_map() do
        specs when map_size(specs) > 0 -> specs
        _empty -> plugin_secrets(config)
      end

    secret_from_table(secrets, plugin_id, secret_id)
  end

  defp secret_from_table(secrets, plugin_id, secret_id)
       when is_binary(plugin_id) and is_map(secrets) do
    case get_key(secrets, plugin_id) do
      %{} = plugin_secrets -> get_key(plugin_secrets, secret_id) || get_key(secrets, secret_id)
      _other -> get_key(secrets, secret_id)
    end
  end

  defp secret_from_table(secrets, _plugin_id, secret_id), do: get_key(secrets, secret_id)

  defp plugin_secrets(%Config{} = config) do
    config
    |> Config.plugins_runtime()
    |> get_key(:secrets)
    |> normalize_map()
  end

  defp plugin_secrets(%{} = config) do
    config
    |> get_key(:plugins)
    |> get_key(:secrets)
    |> normalize_map()
  end

  defp plugin_secrets(_config), do: %{}

  defp resolve_spec(nil, secret_id), do: {:error, {:missing_secret, secret_id}}

  defp resolve_spec(value, secret_id) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:missing_secret, secret_id}}
      secret -> {:ok, secret}
    end
  end

  defp resolve_spec(%{} = spec, secret_id) do
    cond do
      is_binary(get_key(spec, :value)) ->
        resolve_spec(get_key(spec, :value), secret_id)

      is_binary(get_key(spec, :env)) ->
        resolve_env(get_key(spec, :env), secret_id)

      true ->
        {:error, {:unsupported_secret_source, secret_id}}
    end
  end

  defp resolve_spec(_value, secret_id), do: {:error, {:unsupported_secret_source, secret_id}}

  defp resolve_env(env_name, secret_id) do
    env_name = String.trim(env_name)

    cond do
      env_name == "" ->
        {:error, {:missing_secret_env, secret_id}}

      value = System.get_env(env_name) ->
        resolve_spec(value, secret_id)

      true ->
        {:error, {:missing_secret_env, secret_id}}
    end
  end

  defp emit_warning(secret_id, reason, ctx) do
    Log.warning(
      "plugin.secret.resolve.failed",
      %{
        "secret_id" => secret_id,
        "reason_type" => reason_type(reason),
        "plugin_id" => get_key(ctx, :plugin_id)
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new(),
      workspace: workspace(ctx)
    )
  rescue
    _error -> :ok
  end

  defp reason_type({type, _detail}) when is_atom(type), do: Atom.to_string(type)
  defp reason_type(type) when is_atom(type), do: Atom.to_string(type)
  defp reason_type(_reason), do: "error"

  defp workspace(ctx) do
    get_key(ctx, :workspace_root) ||
      ctx |> get_key(:workspace) |> workspace_root() ||
      File.cwd!()
  end

  defp workspace_root(%{} = workspace), do: get_key(workspace, :root)
  defp workspace_root(value) when is_binary(value), do: value
  defp workspace_root(_value), do: nil

  defp normalize_map(%{} = map), do: map
  defp normalize_map(_value), do: %{}

  defp get_key(%{} = map, key) when is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp get_key(%{} = map, key) when is_binary(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      true -> get_existing_atom_key(map, key)
    end
  end

  defp get_key(_value, _key), do: nil

  defp get_existing_atom_key(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
