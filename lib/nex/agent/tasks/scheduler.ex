defmodule Nex.Agent.Tasks.Scheduler do
  @moduledoc false

  @spec normalize_schedule(term()) :: map() | term()
  def normalize_schedule(%{"type" => "every", "seconds" => seconds}),
    do: %{type: :every, seconds: normalize_integer(seconds)}

  def normalize_schedule(%{type: :every, seconds: seconds}),
    do: %{type: :every, seconds: normalize_integer(seconds)}

  def normalize_schedule(%{"type" => "at", "timestamp" => timestamp}),
    do: %{type: :at, timestamp: normalize_integer(timestamp)}

  def normalize_schedule(%{"type" => "at", "at" => timestamp}),
    do: %{type: :at, timestamp: normalize_integer(timestamp)}

  def normalize_schedule(%{type: :at, timestamp: timestamp}),
    do: %{type: :at, timestamp: normalize_integer(timestamp)}

  def normalize_schedule(%{"type" => "cron", "expr" => expr}) when is_binary(expr),
    do: %{type: :cron, expr: expr}

  def normalize_schedule(%{type: :cron, expr: expr}) when is_binary(expr),
    do: %{type: :cron, expr: expr}

  def normalize_schedule(schedule), do: schedule

  @spec next_run(term(), integer()) :: integer() | nil
  def next_run(schedule, now) do
    schedule
    |> normalize_schedule()
    |> calculate_next_run(now)
  end

  @spec due?(term(), integer()) :: boolean()
  def due?(%{enabled: true, next_run: next_run}, now) when is_integer(next_run),
    do: next_run <= now

  def due?(%{"enabled" => true, "next_run" => next_run}, now) when is_integer(next_run),
    do: next_run <= now

  def due?(_task, _now), do: false

  defp calculate_next_run(%{type: :every, seconds: seconds}, now)
       when is_integer(seconds) and seconds > 0,
       do: now + seconds

  defp calculate_next_run(%{type: :at, timestamp: timestamp}, now)
       when is_integer(timestamp) and timestamp > now,
       do: timestamp

  defp calculate_next_run(%{type: :at}, _now), do: nil

  defp calculate_next_run(%{type: :cron, expr: expr}, now) do
    case parse_cron_expr(expr) do
      {:ok, fields} -> next_cron_time(fields, now)
      {:error, _reason} -> nil
    end
  end

  defp calculate_next_run(_schedule, _now), do: nil

  # Standard 5-field cron: minute hour day_of_month month day_of_week.
  # Supports: *, numbers, comma lists, ranges, and steps.
  @spec parse_cron_expr(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp parse_cron_expr(expr) when is_binary(expr) do
    parts = String.split(expr, ~r/\s+/, trim: true)

    if length(parts) == 5 do
      [minute, hour, dom, month, dow] = parts

      with {:ok, min_set} <- parse_field(minute, 0, 59),
           {:ok, hour_set} <- parse_field(hour, 0, 23),
           {:ok, dom_set} <- parse_field(dom, 1, 31),
           {:ok, month_set} <- parse_field(month, 1, 12),
           {:ok, dow_set} <- parse_field(dow, 0, 6) do
        {:ok, %{minute: min_set, hour: hour_set, dom: dom_set, month: month_set, dow: dow_set}}
      end
    else
      {:error, "cron expression must have exactly 5 fields: minute hour dom month dow"}
    end
  end

  defp parse_cron_expr(_expr), do: {:error, "cron expression must be a string"}

  defp parse_field("*", min, max), do: {:ok, MapSet.new(min..max)}

  defp parse_field(field, min, max) do
    field
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case parse_field_part(part, min, max) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_field_part(part, min, max) do
    cond do
      String.starts_with?(part, "*/") ->
        with {step, ""} when step > 0 <- Integer.parse(String.trim_leading(part, "*/")) do
          {:ok, min..max |> Enum.filter(&(rem(&1 - min, step) == 0)) |> MapSet.new()}
        else
          _ -> {:error, "invalid step: #{part}"}
        end

      String.contains?(part, "/") ->
        [range_part, step_str] = String.split(part, "/", parts: 2)

        with {step, ""} when step > 0 <- Integer.parse(step_str),
             {:ok, range_start, range_end} <- parse_range(range_part, min, max) do
          values =
            for value <- range_start..range_end, rem(value - range_start, step) == 0, do: value

          {:ok, MapSet.new(values)}
        else
          _ -> {:error, "invalid range/step: #{part}"}
        end

      String.contains?(part, "-") ->
        case parse_range(part, min, max) do
          {:ok, range_start, range_end} -> {:ok, MapSet.new(range_start..range_end)}
          error -> error
        end

      true ->
        case Integer.parse(part) do
          {number, ""} when number >= min and number <= max -> {:ok, MapSet.new([number])}
          _ -> {:error, "invalid value: #{part}"}
        end
    end
  end

  defp parse_range(range_str, min, max) do
    case String.split(range_str, "-", parts: 2) do
      [left, right] ->
        with {range_start, ""} <- Integer.parse(left),
             {range_end, ""} <- Integer.parse(right),
             true <- range_start >= min and range_end <= max and range_start <= range_end do
          {:ok, range_start, range_end}
        else
          _ -> {:error, "invalid range: #{range_str}"}
        end

      _ ->
        {:error, "invalid range: #{range_str}"}
    end
  end

  @doc false
  @spec next_cron_time(map(), integer()) :: integer() | nil
  def next_cron_time(fields, now) do
    {{year, month, day}, {hour, minute, _second}} =
      :calendar.system_time_to_universal_time(now, :second)

    find_next(fields, {year, month, day, hour, minute + 1}, 0)
  end

  defp find_next(_fields, _datetime, attempts) when attempts > 525_960, do: nil

  defp find_next(fields, {year, month, day, hour, minute}, attempts) do
    {year, month, day, hour, minute} = normalize_datetime(year, month, day, hour, minute)
    dow = day_of_week(year, month, day)

    if MapSet.member?(fields.month, month) and MapSet.member?(fields.dom, day) and
         MapSet.member?(fields.dow, dow) and MapSet.member?(fields.hour, hour) and
         MapSet.member?(fields.minute, minute) and day <= days_in_month(year, month) do
      :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, 0}}) -
        :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
    else
      cond do
        not MapSet.member?(fields.month, month) ->
          find_next(fields, {year, month + 1, 1, 0, 0}, attempts + 1)

        day > days_in_month(year, month) ->
          find_next(fields, {year, month + 1, 1, 0, 0}, attempts + 1)

        not MapSet.member?(fields.dom, day) or not MapSet.member?(fields.dow, dow) ->
          find_next(fields, {year, month, day + 1, 0, 0}, attempts + 1)

        not MapSet.member?(fields.hour, hour) ->
          find_next(fields, {year, month, day, hour + 1, 0}, attempts + 1)

        true ->
          find_next(fields, {year, month, day, hour, minute + 1}, attempts + 1)
      end
    end
  end

  defp normalize_datetime(year, month, day, hour, minute) do
    {hour, minute} =
      if minute > 59, do: {hour + div(minute, 60), rem(minute, 60)}, else: {hour, minute}

    {day, hour} = if hour > 23, do: {day + div(hour, 24), rem(hour, 24)}, else: {day, hour}
    {year, month, day} = normalize_date(year, month, day)
    {year, month, day, hour, minute}
  end

  defp normalize_date(year, month, day) when month > 12 do
    normalize_date(year + div(month - 1, 12), rem(month - 1, 12) + 1, day)
  end

  defp normalize_date(year, month, day) do
    max_day = days_in_month(year, month)

    if day > max_day do
      normalize_date(year, month + 1, day - max_day)
    else
      {year, month, day}
    end
  end

  defp days_in_month(year, 2) do
    if rem(year, 4) == 0 and (rem(year, 100) != 0 or rem(year, 400) == 0), do: 29, else: 28
  end

  defp days_in_month(_year, month) when month in [4, 6, 9, 11], do: 30
  defp days_in_month(_year, _month), do: 31

  # 0=Sunday, 1=Monday, ... 6=Saturday.
  defp day_of_week(year, month, day), do: :calendar.day_of_the_week(year, month, day) |> rem(7)

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> value
    end
  end

  defp normalize_integer(value), do: value
end
