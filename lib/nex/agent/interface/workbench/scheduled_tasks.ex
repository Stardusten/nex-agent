defmodule Nex.Agent.Interface.Workbench.ScheduledTasks do
  @moduledoc false

  alias Nex.Agent.Capability.Cron

  @type bridge_result :: {:ok, map()} | {:error, String.t(), String.t()}

  @max_jobs 500
  @max_name 120
  @max_message 8_000
  @max_channel 160
  @max_chat_id 240
  @max_cron_expr 120
  @max_every_seconds 366 * 24 * 60 * 60

  @spec list(map(), keyword()) :: bridge_result()
  def list(params, opts) when is_map(params) do
    with :ok <- ensure_cron_available(),
         :ok <- ensure_only_keys(params, ~w(limit query status)),
         {:ok, limit} <- parse_limit(Map.get(params, "limit", 200), @max_jobs),
         {:ok, query} <- optional_text(params, "query", 160),
         {:ok, status} <- status_filter(params) do
      jobs =
        opts
        |> Cron.list_jobs()
        |> Enum.map(&job_view/1)
        |> filter_jobs(query, status)

      {:ok,
       %{
         "jobs" => Enum.take(jobs, limit),
         "total" => length(jobs),
         "status" => status_view(Cron.status(opts))
       }}
    else
      {:error, "scheduled task runtime is not running"} ->
        {:error, "unavailable", "scheduled task runtime is not running"}

      {:error, reason} ->
        {:error, "bad_params", reason}
    end
  end

  @spec status(map(), keyword()) :: bridge_result()
  def status(params, opts) when is_map(params) do
    with :ok <- ensure_cron_available(),
         :ok <- ensure_only_keys(params, []) do
      {:ok, %{"status" => status_view(Cron.status(opts))}}
    else
      {:error, "scheduled task runtime is not running"} ->
        {:error, "unavailable", "scheduled task runtime is not running"}

      {:error, reason} ->
        {:error, "bad_params", reason}
    end
  end

  @spec add(map(), keyword()) :: bridge_result()
  def add(params, opts) when is_map(params) do
    with :ok <- ensure_cron_available(),
         :ok <-
           ensure_only_keys(
             params,
             ~w(name message schedule enabled channel chat_id delete_after_run)
           ),
         {:ok, attrs} <- job_attrs(params, :add) do
      case Cron.add_job(attrs, opts) do
        {:ok, job} -> {:ok, %{"job" => job_view(job)}}
        {:error, reason} -> {:error, "failed", inspect(reason, limit: 20, printable_limit: 120)}
      end
    else
      {:error, "scheduled task runtime is not running"} ->
        {:error, "unavailable", "scheduled task runtime is not running"}

      {:error, reason} ->
        {:error, "bad_params", reason}
    end
  end

  @spec update(map(), keyword()) :: bridge_result()
  def update(params, opts) when is_map(params) do
    with :ok <- ensure_cron_available(),
         :ok <-
           ensure_only_keys(
             params,
             ~w(job_id name message schedule enabled channel chat_id delete_after_run)
           ),
         {:ok, job_id} <- required_text(params, "job_id", 80),
         {:ok, attrs} <- job_attrs(params, :update) do
      case Cron.update_job(job_id, attrs, opts) do
        {:ok, job} -> {:ok, %{"job" => job_view(job)}}
        {:error, :not_found} -> {:error, "not_found", "scheduled task not found: #{job_id}"}
      end
    else
      {:error, "scheduled task runtime is not running"} ->
        {:error, "unavailable", "scheduled task runtime is not running"}

      {:error, reason} ->
        {:error, "bad_params", reason}
    end
  end

  @spec remove(map(), keyword()) :: bridge_result()
  def remove(params, opts) when is_map(params) do
    with :ok <- ensure_cron_available(),
         :ok <- ensure_only_keys(params, ~w(job_id)),
         {:ok, job_id} <- required_text(params, "job_id", 80) do
      case Cron.remove_job(job_id, opts) do
        :ok -> {:ok, %{"removed" => true, "job_id" => job_id}}
        {:error, :not_found} -> {:error, "not_found", "scheduled task not found: #{job_id}"}
      end
    else
      {:error, "scheduled task runtime is not running"} ->
        {:error, "unavailable", "scheduled task runtime is not running"}

      {:error, reason} ->
        {:error, "bad_params", reason}
    end
  end

  @spec enable(map(), keyword(), boolean()) :: bridge_result()
  def enable(params, opts, enabled) when is_map(params) and is_boolean(enabled) do
    with :ok <- ensure_cron_available(),
         :ok <- ensure_only_keys(params, ~w(job_id)),
         {:ok, job_id} <- required_text(params, "job_id", 80) do
      case Cron.enable_job(job_id, enabled, opts) do
        {:ok, job} -> {:ok, %{"job" => job_view(job)}}
        {:error, :not_found} -> {:error, "not_found", "scheduled task not found: #{job_id}"}
      end
    else
      {:error, "scheduled task runtime is not running"} ->
        {:error, "unavailable", "scheduled task runtime is not running"}

      {:error, reason} ->
        {:error, "bad_params", reason}
    end
  end

  @spec run(map(), keyword()) :: bridge_result()
  def run(params, opts) when is_map(params) do
    with :ok <- ensure_cron_available(),
         :ok <- ensure_only_keys(params, ~w(job_id)),
         {:ok, job_id} <- required_text(params, "job_id", 80) do
      case Cron.run_job(job_id, opts) do
        {:ok, job} -> {:ok, %{"triggered" => true, "job" => job_view(job)}}
        {:error, :not_found} -> {:error, "not_found", "scheduled task not found: #{job_id}"}
      end
    else
      {:error, "scheduled task runtime is not running"} ->
        {:error, "unavailable", "scheduled task runtime is not running"}

      {:error, reason} ->
        {:error, "bad_params", reason}
    end
  end

  defp job_attrs(params, mode) do
    with {:ok, attrs} <- maybe_put_required_text(%{}, params, "name", :name, @max_name, mode),
         {:ok, attrs} <-
           maybe_put_required_text(attrs, params, "message", :message, @max_message, mode),
         {:ok, attrs} <- maybe_put_schedule(attrs, params, mode),
         {:ok, attrs} <- maybe_put_bool(attrs, params, "enabled", :enabled),
         {:ok, attrs} <- maybe_put_optional_text(attrs, params, "channel", :channel, @max_channel),
         {:ok, attrs} <-
           maybe_put_optional_text(attrs, params, "chat_id", :chat_id, @max_chat_id),
         {:ok, attrs} <-
           maybe_put_delete_after_run(attrs, params, mode) do
      {:ok, attrs}
    end
  end

  defp maybe_put_required_text(attrs, params, key, attr_key, limit, :add) do
    with {:ok, value} <- required_text(params, key, limit) do
      {:ok, Map.put(attrs, attr_key, value)}
    end
  end

  defp maybe_put_required_text(attrs, params, key, attr_key, limit, :update) do
    if Map.has_key?(params, key) do
      with {:ok, value} <- required_text(params, key, limit) do
        {:ok, Map.put(attrs, attr_key, value)}
      end
    else
      {:ok, attrs}
    end
  end

  defp maybe_put_schedule(attrs, params, :add) do
    with {:ok, schedule} <- schedule_param(Map.get(params, "schedule")) do
      {:ok, Map.put(attrs, :schedule, schedule)}
    end
  end

  defp maybe_put_schedule(attrs, params, :update) do
    if Map.has_key?(params, "schedule") do
      with {:ok, schedule} <- schedule_param(Map.get(params, "schedule")) do
        {:ok, Map.put(attrs, :schedule, schedule)}
      end
    else
      {:ok, attrs}
    end
  end

  defp maybe_put_bool(attrs, params, key, attr_key) do
    if Map.has_key?(params, key) do
      with {:ok, value} <- bool_param(Map.get(params, key), key) do
        {:ok, Map.put(attrs, attr_key, value)}
      end
    else
      {:ok, attrs}
    end
  end

  defp maybe_put_optional_text(attrs, params, key, attr_key, limit) do
    if Map.has_key?(params, key) do
      with {:ok, value} <- optional_text(params, key, limit) do
        {:ok, Map.put(attrs, attr_key, value)}
      end
    else
      {:ok, attrs}
    end
  end

  defp maybe_put_delete_after_run(attrs, params, mode) do
    cond do
      Map.has_key?(params, "delete_after_run") ->
        with {:ok, value} <- bool_param(Map.get(params, "delete_after_run"), "delete_after_run") do
          {:ok, Map.put(attrs, :delete_after_run, value)}
        end

      mode == :add and match?(%{type: :at}, Map.get(attrs, :schedule)) ->
        {:ok, Map.put(attrs, :delete_after_run, true)}

      true ->
        {:ok, attrs}
    end
  end

  defp schedule_param(%{} = schedule) do
    schedule = stringify_keys(schedule)

    case schedule["type"] |> to_string() |> String.trim() |> String.downcase() do
      "every" ->
        with {:ok, seconds} <- positive_int(schedule["seconds"], "schedule.seconds") do
          {:ok, %{type: :every, seconds: seconds}}
        end

      "cron" ->
        with {:ok, expr} <- cron_expr(schedule["expr"]) do
          {:ok, %{type: :cron, expr: expr}}
        end

      "at" ->
        with {:ok, timestamp} <- timestamp_param(schedule["at"] || schedule["timestamp"]) do
          {:ok, %{type: :at, timestamp: timestamp}}
        end

      "" ->
        {:error, "schedule.type is required"}

      other ->
        {:error, "unsupported schedule.type: #{other}"}
    end
  end

  defp schedule_param(_schedule), do: {:error, "schedule must be an object"}

  defp cron_expr(value) when is_binary(value) do
    expr = String.trim(value)
    parts = String.split(expr, ~r/\s+/, trim: true)

    cond do
      expr == "" -> {:error, "schedule.expr is required"}
      String.length(expr) > @max_cron_expr -> {:error, "schedule.expr is too long"}
      length(parts) != 5 -> {:error, "cron expression must have 5 fields"}
      true -> {:ok, Enum.join(parts, " ")}
    end
  end

  defp cron_expr(_value), do: {:error, "schedule.expr must be a string"}

  defp timestamp_param(value) when is_integer(value), do: {:ok, value}

  defp timestamp_param(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {timestamp, ""} ->
        {:ok, timestamp}

      _ ->
        parse_iso_timestamp(value)
    end
  end

  defp timestamp_param(_value),
    do: {:error, "schedule.at must be an ISO datetime or unix timestamp"}

  defp parse_iso_timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, DateTime.to_unix(dt)}

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()}
          {:error, _reason} -> {:error, "schedule.at must be a valid ISO datetime"}
        end
    end
  end

  defp positive_int(value, field) when is_integer(value) do
    if value > 0 and value <= @max_every_seconds do
      {:ok, value}
    else
      {:error, "#{field} must be between 1 and #{@max_every_seconds}"}
    end
  end

  defp positive_int(value, field) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> positive_int(parsed, field)
      _ -> {:error, "#{field} must be a positive integer"}
    end
  end

  defp positive_int(_value, field), do: {:error, "#{field} must be a positive integer"}

  defp bool_param(value, _field) when is_boolean(value), do: {:ok, value}

  defp bool_param(value, field) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "#{field} must be true or false"}
    end
  end

  defp bool_param(_value, field), do: {:error, "#{field} must be true or false"}

  defp required_text(params, key, limit) do
    case optional_text(params, key, limit) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, nil} -> {:error, "#{key} is required"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_text(params, key, limit) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          value == "" ->
            {:ok, nil}

          String.length(value) > limit ->
            {:error, "#{key} must be at most #{limit} characters"}

          String.match?(value, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/) ->
            {:error, "#{key} has invalid control characters"}

          true ->
            {:ok, value}
        end

      value ->
        optional_text(Map.put(params, key, to_string(value)), key, limit)
    end
  end

  defp status_filter(params) do
    case params
         |> Map.get("status", "all")
         |> to_string()
         |> String.trim()
         |> String.downcase() do
      value when value in ["all", "enabled", "disabled"] -> {:ok, value}
      _ -> {:error, "status must be all, enabled, or disabled"}
    end
  end

  defp filter_jobs(jobs, query, status) do
    jobs
    |> Enum.filter(fn job ->
      case status do
        "enabled" -> job["enabled"]
        "disabled" -> not job["enabled"]
        _ -> true
      end
    end)
    |> Enum.filter(fn job ->
      case query do
        nil ->
          true

        query ->
          haystack =
            [job["name"], job["message"], job["channel"], job["chat_id"], job["id"]]
            |> Enum.join("\n")
            |> String.downcase()

          String.contains?(haystack, String.downcase(query))
      end
    end)
  end

  defp job_view(%Cron{} = job) do
    %{
      "id" => job.id,
      "name" => job.name,
      "message" => job.message || "",
      "enabled" => job.enabled == true,
      "schedule" => schedule_view(job.schedule),
      "channel" => job.channel,
      "chat_id" => job.chat_id,
      "delete_after_run" => job.delete_after_run == true,
      "last_run" => iso_timestamp(job.last_run),
      "next_run" => iso_timestamp(job.next_run),
      "last_run_unix" => job.last_run,
      "next_run_unix" => job.next_run,
      "last_status" => job.last_status,
      "last_error" => job.last_error,
      "created_at" => iso_timestamp(job.created_at),
      "updated_at" => iso_timestamp(job.updated_at),
      "source" => job_source(job.name)
    }
  end

  defp schedule_view(%{type: :every, seconds: seconds}) do
    %{"type" => "every", "seconds" => seconds, "label" => "every #{format_duration(seconds)}"}
  end

  defp schedule_view(%{type: :cron, expr: expr}) do
    %{"type" => "cron", "expr" => expr, "label" => "cron #{expr}"}
  end

  defp schedule_view(%{type: :at, timestamp: timestamp}) do
    %{
      "type" => "at",
      "timestamp" => timestamp,
      "at" => iso_timestamp(timestamp),
      "label" => "at #{iso_timestamp(timestamp) || timestamp}"
    }
  end

  defp schedule_view(other), do: %{"type" => "unknown", "raw" => inspect(other, limit: 10)}

  defp status_view(status) when is_map(status) do
    %{
      "total" => Map.get(status, :total, 0),
      "enabled" => Map.get(status, :enabled, 0),
      "disabled" => Map.get(status, :disabled, 0),
      "next_wakeup" => Map.get(status, :next_wakeup),
      "next_wakeup_at" => iso_timestamp(Map.get(status, :next_wakeup)),
      "next_wakeup_in" => Map.get(status, :next_wakeup_in)
    }
  end

  defp job_source("task_due:" <> task_id),
    do: %{"type" => "personal_task", "kind" => "due", "task_id" => task_id}

  defp job_source("task_follow_up:" <> task_id),
    do: %{"type" => "personal_task", "kind" => "follow_up", "task_id" => task_id}

  defp job_source(_name), do: %{"type" => "scheduled_task", "kind" => "custom"}

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 86_400,
    do: "#{div(seconds, 86_400)}d"

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 3_600,
    do: "#{div(seconds, 3_600)}h"

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 60,
    do: "#{div(seconds, 60)}m"

  defp format_duration(seconds), do: "#{seconds}s"

  defp iso_timestamp(nil), do: nil

  defp iso_timestamp(timestamp) when is_integer(timestamp) do
    timestamp
    |> DateTime.from_unix()
    |> case do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      {:error, _reason} -> nil
    end
  end

  defp iso_timestamp(_timestamp), do: nil

  defp parse_limit(value, max) when is_integer(value) and value > 0, do: {:ok, min(value, max)}

  defp parse_limit(value, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, min(parsed, max)}
      _ -> {:error, "limit must be a positive integer"}
    end
  end

  defp parse_limit(_value, _max), do: {:error, "limit must be a positive integer"}

  defp ensure_only_keys(params, allowed_keys) do
    case params |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in allowed_keys)) do
      [] -> :ok
      [key | _] -> {:error, "unsupported param: #{key}"}
    end
  end

  defp ensure_cron_available do
    if Process.whereis(Cron), do: :ok, else: {:error, "scheduled task runtime is not running"}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
