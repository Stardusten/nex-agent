defmodule Nex.Agent.Interface.Auth.Codex do
  @moduledoc false

  @default_base_url "https://chatgpt.com/backend-api/codex"
  @oauth_client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @oauth_token_url "https://auth.openai.com/oauth/token"
  @refresh_skew_seconds 120
  @request_timeout 20_000

  @type tokens :: %{
          optional(:access_token) => String.t(),
          optional(:refresh_token) => String.t()
        }

  @spec default_base_url() :: String.t()
  def default_base_url, do: @default_base_url

  @spec auth_path() :: String.t()
  def auth_path do
    Path.join(codex_home(), "auth.json")
  end

  @spec resolve_access_token(keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_access_token(opts \\ []) do
    with {:ok, state} <- read_state(),
         {:ok, refreshed} <- maybe_refresh_state(state, opts),
         {:ok, access_token} <- fetch_access_token(refreshed) do
      {:ok, access_token}
    end
  end

  @doc """
  Resolve API key for custom (non-OAuth) codex usage.

  Reads `~/.codex/auth.json` and returns:
  - `OPENAI_API_KEY` field if present and non-empty
  - Otherwise falls back to `tokens.access_token`
  """
  @spec resolve_custom_api_key() :: {:ok, String.t()} | {:error, term()}
  def resolve_custom_api_key do
    with {:ok, state} <- read_state() do
      case Map.get(state, "OPENAI_API_KEY") do
        key when is_binary(key) and key != "" ->
          {:ok, key}

        _ ->
          case extract_tokens(state) do
            %{access_token: token} when is_binary(token) and token != "" -> {:ok, token}
            _ -> {:error, :no_api_key_in_codex_auth}
          end
      end
    end
  end

  @doc """
  Read `~/.codex/config.toml` and return the parsed map.
  """
  @spec read_config() :: {:ok, map()} | {:error, term()}
  def read_config do
    path = config_path()

    cond do
      not File.exists?(path) ->
        {:error, {:missing_config_file, path}}

      true ->
        case File.read(path) do
          {:ok, contents} ->
            case Toml.decode(contents) do
              {:ok, data} when is_map(data) -> {:ok, data}
              {:ok, _} -> {:error, {:invalid_config_file, path}}
              {:error, reason} -> {:error, {:invalid_config_toml, path, reason}}
            end

          {:error, reason} ->
            {:error, {:read_config_file_failed, path, reason}}
        end
    end
  end

  @doc """
  Resolve base_url from `~/.codex/config.toml` for the active model provider.

  Reads `model_provider` to find the provider name, then looks up
  `model_providers.<name>.base_url`.
  """
  @spec resolve_custom_base_url() :: {:ok, String.t()} | {:error, term()}
  def resolve_custom_base_url do
    with {:ok, config} <- read_config() do
      provider_name = Map.get(config, "model_provider")

      base_url =
        config
        |> Map.get("model_providers", %{})
        |> Map.get(provider_name, %{})
        |> Map.get("base_url")

      case base_url do
        url when is_binary(url) and url != "" -> {:ok, url}
        _ -> {:error, :no_base_url_in_codex_config}
      end
    end
  end

  @spec access_token_is_expiring?(String.t(), non_neg_integer()) :: boolean()
  def access_token_is_expiring?(token, skew_seconds \\ @refresh_skew_seconds)

  def access_token_is_expiring?(token, skew_seconds) when is_binary(token) do
    case token_expiration(token) do
      {:ok, exp} -> exp <= System.system_time(:second) + max(skew_seconds, 0)
      :error -> false
    end
  end

  def access_token_is_expiring?(_, _), do: true

  @spec read_state() :: {:ok, map()} | {:error, term()}
  def read_state do
    path = auth_path()

    cond do
      not File.exists?(path) ->
        {:error, {:missing_auth_file, path}}

      true ->
        case File.read(path) do
          {:ok, contents} ->
            case Jason.decode(contents) do
              {:ok, data} when is_map(data) -> {:ok, data}
              {:ok, _} -> {:error, {:invalid_auth_file, path}}
              {:error, reason} -> {:error, {:invalid_auth_json, path, reason}}
            end

          {:error, reason} ->
            {:error, {:read_auth_file_failed, path, reason}}
        end
    end
  end

  defp maybe_refresh_state(state, opts) do
    tokens = extract_tokens(state)
    refresh_fun = Keyword.get(opts, :refresh_fun, &refresh_tokens/1)

    if token_refresh_required?(tokens) do
      with {:ok, refreshed_tokens} <- refresh_fun.(tokens),
           {:ok, updated_state} <- persist_refreshed_tokens(state, refreshed_tokens) do
        {:ok, updated_state}
      end
    else
      {:ok, state}
    end
  end

  defp token_refresh_required?(tokens) do
    access_token = Map.get(tokens, :access_token)
    refresh_token = Map.get(tokens, :refresh_token)

    not is_binary(access_token) or access_token == "" or
      (is_binary(refresh_token) and refresh_token != "" and
         access_token_is_expiring?(access_token, @refresh_skew_seconds))
  end

  defp fetch_access_token(state) do
    case extract_tokens(state) do
      %{access_token: token} when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_access_token}
    end
  end

  @spec refresh_tokens(tokens()) :: {:ok, tokens()} | {:error, term()}
  def refresh_tokens(tokens) when is_map(tokens) do
    refresh_token = Map.get(tokens, :refresh_token, "")

    if not (is_binary(refresh_token) and refresh_token != "") do
      {:error, :missing_refresh_token}
    else
      body =
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh_token,
          "client_id" => @oauth_client_id
        })

      request = {
        String.to_charlist(@oauth_token_url),
        [
          {~c"accept", ~c"application/json"},
          {~c"content-type", ~c"application/x-www-form-urlencoded"}
        ],
        ~c"application/x-www-form-urlencoded",
        String.to_charlist(body)
      }

      http_opts = [timeout: @request_timeout, connect_timeout: @request_timeout]

      case :httpc.request(:post, request, http_opts, body_format: :binary) do
        {:ok, {{_, 200, _}, _headers, response_body}} ->
          decode_refresh_response(response_body, refresh_token)

        {:ok, {{_, status, _}, _headers, response_body}} ->
          {:error, {:refresh_failed, status, response_body}}

        {:error, reason} ->
          {:error, {:refresh_request_failed, reason}}
      end
    end
  end

  defp decode_refresh_response(body, fallback_refresh_token) do
    with {:ok, payload} <- Jason.decode(body),
         access_token when is_binary(access_token) and access_token != "" <-
           Map.get(payload, "access_token") do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: Map.get(payload, "refresh_token", fallback_refresh_token)
       }}
    else
      {:error, reason} -> {:error, {:refresh_invalid_json, reason}}
      _ -> {:error, :refresh_missing_access_token}
    end
  end

  defp persist_refreshed_tokens(state, refreshed_tokens) do
    updated_state =
      state
      |> Map.put(
        "tokens",
        Map.merge(
          Map.get(state, "tokens", %{}),
          %{
            "access_token" => refreshed_tokens.access_token,
            "refresh_token" => refreshed_tokens.refresh_token
          }
        )
      )
      |> Map.put(
        "last_refresh",
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )

    case write_state(updated_state) do
      :ok -> {:ok, updated_state}
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  defp write_state(state) do
    path = auth_path()
    dir = Path.dirname(path)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, Jason.encode!(state, pretty: true) <> "\n"),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(tmp)
        error
    end
  end

  defp extract_tokens(state) when is_map(state) do
    case Map.get(state, "tokens") do
      %{"access_token" => access_token, "refresh_token" => refresh_token} ->
        %{access_token: access_token, refresh_token: refresh_token}

      %{"access_token" => access_token} ->
        %{access_token: access_token, refresh_token: nil}

      _ ->
        %{access_token: nil, refresh_token: nil}
    end
  end

  defp token_expiration(token) do
    with [_header, payload, _sig] <- String.split(token, ".", parts: 3),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded),
         exp when is_integer(exp) <- Map.get(claims, "exp") do
      {:ok, exp}
    else
      _ -> :error
    end
  end

  defp codex_home do
    case System.get_env("CODEX_HOME") do
      home when is_binary(home) and home != "" -> home
      _ -> Path.join(System.get_env("HOME", "~"), ".codex")
    end
  end

  defp config_path do
    Path.join(codex_home(), "config.toml")
  end
end
