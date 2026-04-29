defmodule Nex.Agent.Interface.Workbench.Bridge do
  @moduledoc false

  alias Nex.Agent.Observe.ControlPlane.{Log, Query}
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Interface.Workbench.{Notes, Permissions, ScheduledTasks}
  require Log

  @message_limit 500
  @observe_query_keys ~w(tag tag_prefix kind level run_id session_key channel chat_id tool tool_call_id tool_name trace_id query since limit)

  @methods %{
    "permissions.current" => "permissions:read",
    "observe.summary" => "observe:read",
    "observe.query" => "observe:read",
    "notes.roots.list" => "notes:read",
    "notes.files.list" => "notes:read",
    "notes.file.read" => "notes:read",
    "notes.file.write" => "notes:write",
    "notes.file.delete" => "notes:write",
    "notes.search" => "notes:read",
    "tasks.scheduled.list" => "tasks:read",
    "tasks.scheduled.status" => "tasks:read",
    "tasks.scheduled.add" => "tasks:write",
    "tasks.scheduled.update" => "tasks:write",
    "tasks.scheduled.remove" => "tasks:write",
    "tasks.scheduled.enable" => "tasks:write",
    "tasks.scheduled.disable" => "tasks:write",
    "tasks.scheduled.run" => "tasks:write"
  }

  @spec call(String.t(), map(), Snapshot.t() | keyword()) :: map()
  def call(app_id, request, %Snapshot{} = snapshot) when is_binary(app_id) and is_map(request) do
    call(app_id, request,
      workspace: snapshot.workspace,
      config: snapshot.config,
      runtime_snapshot: snapshot
    )
  end

  def call(app_id, request, opts) when is_binary(app_id) and is_map(request) and is_list(opts) do
    case normalize_request(request) do
      {:ok, normalized} ->
        dispatch(app_id, normalized, opts)

      {:error, call_id, code, message} ->
        _ = observe_failed(app_id, call_id, nil, code, message, opts)
        error_response(call_id, code, message)
    end
  end

  def call(app_id, _request, opts) when is_binary(app_id) and is_list(opts) do
    _ = observe_failed(app_id, "", nil, "bad_request", "request body must be a JSON object", opts)
    error_response("", "bad_request", "request body must be a JSON object")
  end

  defp dispatch(app_id, %{"call_id" => call_id, "method" => method, "params" => params}, opts) do
    case Map.fetch(@methods, method) do
      {:ok, permission} ->
        attrs = %{
          "app_id" => app_id,
          "call_id" => call_id,
          "method" => method,
          "permission" => permission
        }

        _ = Log.info("workbench.bridge.call.started", attrs, opts)

        case Permissions.check(app_id, permission, opts) do
          :ok ->
            execute_allowed(
              app_id,
              call_id,
              method,
              params,
              attrs,
              Keyword.put(opts, :bridge_app_id, app_id)
            )

          {:error, reason} ->
            _ =
              Log.warning(
                "workbench.bridge.call.denied",
                Map.put(attrs, "reason", bounded(reason)),
                opts
              )

            error_response(call_id, "permission_denied", reason)
        end

      :error ->
        _ =
          observe_failed(
            app_id,
            call_id,
            method,
            "unknown_method",
            "bridge method is not allowed",
            opts
          )

        error_response(call_id, "unknown_method", "bridge method is not allowed")
    end
  end

  defp execute_allowed(app_id, call_id, method, params, attrs, opts) do
    case execute(method, params, opts) do
      {:ok, result} ->
        _ =
          Log.info(
            "workbench.bridge.call.finished",
            Map.merge(attrs, %{"result_status" => "ok"}),
            opts
          )

        %{"call_id" => call_id, "ok" => true, "result" => result}

      {:error, code, reason} ->
        _ = observe_failed(app_id, call_id, method, code, reason, opts)
        error_response(call_id, code, reason)
    end
  end

  defp execute("permissions.current", params, opts) do
    with :ok <- ensure_no_params(params),
         app_id when is_binary(app_id) <- Keyword.get(opts, :bridge_app_id) do
      case Permissions.app(app_id, opts) do
        {:ok, view} -> {:ok, view}
        {:error, reason} -> {:error, "not_found", reason}
      end
    else
      {:error, reason} -> {:error, "bad_params", reason}
      _ -> {:error, "internal_error", "bridge app id is unavailable"}
    end
  end

  defp execute("observe.summary", params, opts) do
    with {:ok, limit} <- optional_limit(params, 20, ~w(limit)) do
      {:ok, Query.summary(Keyword.put(opts, :limit, limit))}
    else
      {:error, reason} -> {:error, "bad_params", reason}
    end
  end

  defp execute("observe.query", params, opts) do
    with {:ok, filters} <- observe_query_filters(params) do
      {:ok, %{"filters" => filters, "observations" => Query.query(filters, opts)}}
    else
      {:error, reason} -> {:error, "bad_params", reason}
    end
  end

  defp execute("notes.roots.list", params, opts), do: Notes.roots_list(params, opts)
  defp execute("notes.files.list", params, opts), do: Notes.files_list(params, opts)
  defp execute("notes.file.read", params, opts), do: Notes.file_read(params, opts)
  defp execute("notes.file.write", params, opts), do: Notes.file_write(params, opts)
  defp execute("notes.file.delete", params, opts), do: Notes.file_delete(params, opts)
  defp execute("notes.search", params, opts), do: Notes.search(params, opts)
  defp execute("tasks.scheduled.list", params, opts), do: ScheduledTasks.list(params, opts)
  defp execute("tasks.scheduled.status", params, opts), do: ScheduledTasks.status(params, opts)
  defp execute("tasks.scheduled.add", params, opts), do: ScheduledTasks.add(params, opts)
  defp execute("tasks.scheduled.update", params, opts), do: ScheduledTasks.update(params, opts)
  defp execute("tasks.scheduled.remove", params, opts), do: ScheduledTasks.remove(params, opts)

  defp execute("tasks.scheduled.enable", params, opts),
    do: ScheduledTasks.enable(params, opts, true)

  defp execute("tasks.scheduled.disable", params, opts),
    do: ScheduledTasks.enable(params, opts, false)

  defp execute("tasks.scheduled.run", params, opts), do: ScheduledTasks.run(params, opts)

  defp execute(_method, _params, _opts),
    do: {:error, "unknown_method", "bridge method is not allowed"}

  defp normalize_request(request) do
    call_id = request |> Map.get("call_id", "") |> to_string() |> String.trim()
    method = request |> Map.get("method", "") |> to_string() |> String.trim()
    params = Map.get(request, "params", %{})

    cond do
      call_id == "" ->
        {:error, "", "bad_request", "call_id is required"}

      method == "" ->
        {:error, call_id, "bad_request", "method is required"}

      not is_map(params) ->
        {:error, call_id, "bad_request", "params must be an object"}

      true ->
        {:ok, %{"call_id" => call_id, "method" => method, "params" => params}}
    end
  end

  defp ensure_no_params(params) when map_size(params) == 0, do: :ok
  defp ensure_no_params(_params), do: {:error, "params must be empty"}

  defp optional_limit(params, default, allowed_keys) when is_map(params) do
    with :ok <- ensure_only_keys(params, allowed_keys),
         {:ok, limit} <- parse_limit(Map.get(params, "limit", default)) do
      {:ok, limit}
    end
  end

  defp observe_query_filters(params) when is_map(params) do
    with :ok <- ensure_only_keys(params, @observe_query_keys),
         {:ok, limit} <- parse_limit(Map.get(params, "limit", 80)) do
      filters =
        params
        |> Map.take(@observe_query_keys)
        |> Enum.reject(fn {_key, value} -> blank?(value) end)
        |> Map.new(fn
          {"limit", _value} -> {"limit", limit}
          {key, value} -> {key, to_string(value)}
        end)
        |> Map.put_new("limit", limit)

      {:ok, filters}
    end
  end

  defp ensure_only_keys(params, allowed_keys) do
    case params |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in allowed_keys)) do
      [] -> :ok
      [key | _] -> {:error, "unsupported param: #{key}"}
    end
  end

  defp parse_limit(value) when is_integer(value) and value > 0, do: {:ok, min(value, 500)}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, min(parsed, 500)}
      _ -> {:error, "limit must be a positive integer"}
    end
  end

  defp parse_limit(_value), do: {:error, "limit must be a positive integer"}

  defp observe_failed(app_id, call_id, method, code, reason, opts) do
    Log.warning(
      "workbench.bridge.call.failed",
      %{
        "app_id" => app_id,
        "call_id" => call_id,
        "method" => method,
        "code" => code,
        "reason" => bounded(reason)
      },
      opts
    )
  end

  defp error_response(call_id, code, message) do
    %{
      "call_id" => call_id || "",
      "ok" => false,
      "error" => %{
        "code" => code,
        "message" => bounded(message)
      }
    }
  end

  defp bounded(message) do
    message = to_string(message)

    if String.length(message) > @message_limit do
      String.slice(message, 0, @message_limit) <> "...[truncated]"
    else
      message
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
