defmodule Nex.Agent.Workbench.Router do
  @moduledoc false

  alias Nex.Agent.ControlPlane.Query
  alias Nex.Agent.Runtime.Snapshot

  alias Nex.Agent.Workbench.{
    AppManifest,
    Assets,
    Bridge,
    ConfigPanel,
    EvolutionApp,
    Permissions,
    SessionApp,
    Shell,
    Store
  }

  @type response ::
          {pos_integer(), map()}
          | {:html, pos_integer(), String.t()}
          | {:asset, pos_integer(), String.t(), binary()}

  @observe_filter_keys ~w(tag tag_prefix kind level run_id session_key channel chat_id tool tool_call_id tool_name trace_id query since limit)

  @spec dispatch(String.t(), String.t(), binary(), Snapshot.t()) :: response()
  def dispatch(method, target, body, %Snapshot{} = snapshot) do
    uri = URI.parse(to_string(target))
    segments = path_segments(uri.path || "/")
    query_params = URI.decode_query(uri.query || "")
    workspace_opts = [workspace: snapshot.workspace]

    case {method, segments} do
      {"GET", []} ->
        {:html, 200, Shell.html()}

      {"GET", ["workbench"]} ->
        {:html, 200, Shell.html()}

      {"GET", ["app-frame", app_id]} ->
        case Assets.app_frame(app_id, workspace_opts) do
          {:ok, html} -> {:html, 200, html}
          {:error, status, html} -> {:html, status, html}
        end

      {"GET", ["app-assets", app_id | asset_segments]} ->
        relative_path = Enum.join(asset_segments, "/")

        case Assets.asset(app_id, relative_path, workspace_opts) do
          {:ok, %{content_type: content_type, body: asset_body}} ->
            {:asset, 200, content_type, asset_body}

          {:error, status, reason} ->
            {status, %{"error" => reason}}
        end

      {"GET", ["api", "workbench", "apps"]} ->
        %{"apps" => apps, "diagnostics" => diagnostics} = Store.load_all(workspace_opts)

        {200,
         %{
           "apps" => Enum.map(apps, &AppManifest.to_map/1),
           "diagnostics" => diagnostics
         }}

      {"GET", ["api", "workbench", "apps", app_id]} ->
        case Store.get(app_id, workspace_opts) do
          {:ok, manifest} -> {200, %{"app" => AppManifest.to_map(manifest)}}
          {:error, reason} -> {404, %{"error" => reason}}
        end

      {"GET", ["api", "workbench", "permissions", app_id]} ->
        case Permissions.app(app_id, workspace_opts) do
          {:ok, view} -> {200, %{"permissions" => view}}
          {:error, reason} -> {404, %{"error" => reason}}
        end

      {"GET", ["api", "workbench", "config"]} ->
        case ConfigPanel.overview(snapshot) do
          {:ok, payload} -> {200, payload}
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"PUT", ["api", "workbench", "config", "providers", provider_key]} ->
        with {:ok, args} <- decode_json_object(body),
             {:ok, payload} <- ConfigPanel.upsert_provider(provider_key, args, snapshot) do
          {200, payload}
        else
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"DELETE", ["api", "workbench", "config", "providers", provider_key]} ->
        case ConfigPanel.delete_provider(provider_key, snapshot) do
          {:ok, payload} -> {200, payload}
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"PUT", ["api", "workbench", "config", "models", model_key]} ->
        with {:ok, args} <- decode_json_object(body),
             {:ok, payload} <- ConfigPanel.upsert_model(model_key, args, snapshot) do
          {200, payload}
        else
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"DELETE", ["api", "workbench", "config", "models", model_key]} ->
        case ConfigPanel.delete_model(model_key, snapshot) do
          {:ok, payload} -> {200, payload}
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"PATCH", ["api", "workbench", "config", "model-roles"]} ->
        with {:ok, args} <- decode_json_object(body),
             {:ok, payload} <- ConfigPanel.update_model_roles(args, snapshot) do
          {200, payload}
        else
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"PUT", ["api", "workbench", "config", "channels", channel_id]} ->
        with {:ok, args} <- decode_json_object(body),
             {:ok, payload} <- ConfigPanel.upsert_channel(channel_id, args, snapshot) do
          {200, payload}
        else
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"DELETE", ["api", "workbench", "config", "channels", channel_id]} ->
        case ConfigPanel.delete_channel(channel_id, snapshot) do
          {:ok, payload} -> {200, payload}
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"POST", ["api", "workbench", "permissions", app_id, "grant"]} ->
        with {:ok, args} <- decode_json_object(body),
             {:ok, view} <- Permissions.grant(app_id, Map.get(args, "permission"), workspace_opts) do
          {200, %{"permissions" => view}}
        else
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"POST", ["api", "workbench", "permissions", app_id, "revoke"]} ->
        with {:ok, args} <- decode_json_object(body),
             {:ok, view} <-
               Permissions.revoke(app_id, Map.get(args, "permission"), workspace_opts) do
          {200, %{"permissions" => view}}
        else
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"POST", ["api", "workbench", "bridge", app_id, "call"]} ->
        with {:ok, args} <- decode_json_object(body) do
          {200, Bridge.call(app_id, args, snapshot)}
        else
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"GET", ["api", "observe", "summary"]} ->
        {200, Query.summary(Keyword.put(workspace_opts, :limit, observe_limit(query_params, 20)))}

      {"GET", ["api", "observe", "query"]} ->
        filters = observe_filters(query_params)
        {200, %{"filters" => filters, "observations" => Query.query(filters, workspace_opts)}}

      {"GET", ["api", "workbench", "sessions"]} ->
        {200, SessionApp.overview(snapshot)}

      {"GET", ["api", "workbench", "sessions", session_key]} ->
        case SessionApp.detail(session_key, snapshot) do
          {:ok, view} -> {200, view}
          {:error, reason} -> {404, %{"error" => reason}}
        end

      {"POST", ["api", "workbench", "sessions", session_key, "stop"]} ->
        with {:ok, args} <- decode_json_object(body),
             {:ok, result} <- SessionApp.stop(session_key, snapshot, args) do
          {200, result}
        else
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"POST", ["api", "workbench", "sessions", session_key, "model"]} ->
        with {:ok, args} <- decode_json_object(body),
             {:ok, result} <- SessionApp.set_model(session_key, snapshot, args) do
          {200, result}
        else
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"GET", ["api", "workbench", "evolution"]} ->
        {200, EvolutionApp.overview(workspace_opts)}

      {"GET", ["api", "workbench", "evolution", "candidates", candidate_id]} ->
        case EvolutionApp.candidate(candidate_id, workspace_opts) do
          {:ok, candidate} -> {200, %{"candidate" => candidate}}
          {:error, reason} -> {404, %{"error" => reason}}
        end

      {"POST", ["api", "workbench", "evolution", "candidates", candidate_id, action]} ->
        with {:ok, args} <- decode_json_object(body),
             {:ok, result} <-
               EvolutionApp.perform_action(candidate_id, action, args, workspace_opts) do
          {200, %{"result" => result}}
        else
          {:error, reason} -> {400, %{"error" => reason}}
        end

      {"OPTIONS", _segments} ->
        {204, %{}}

      {_method, _segments} ->
        {404, %{"error" => "not found"}}
    end
  rescue
    e -> {500, %{"error" => bounded_error(Exception.message(e))}}
  end

  defp path_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&URI.decode/1)
  end

  defp decode_json_object(body) when is_binary(body) do
    case Jason.decode((body == "" && "{}") || body) do
      {:ok, %{} = map} ->
        {:ok, map}

      {:ok, _other} ->
        {:error, "request body must be a JSON object"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "invalid JSON: #{Exception.message(error)}"}
    end
  end

  defp bounded_error(message) do
    message = to_string(message)

    if String.length(message) > 500 do
      String.slice(message, 0, 500) <> "...[truncated]"
    else
      message
    end
  end

  defp observe_filters(params) do
    params
    |> Map.take(@observe_filter_keys)
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
    |> Map.put_new("limit", "80")
  end

  defp observe_limit(params, default) do
    params
    |> Map.get("limit")
    |> case do
      nil -> default
      value -> value
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
