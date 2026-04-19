defmodule Nex.Agent.FollowUp do
  @moduledoc """
  Busy-session follow-up helpers.

  A follow-up turn is not an owner run. It may read owner run state and produce
  a side answer, but it must not mutate the owner history or use side-effecting
  tools.
  """

  alias Nex.Agent.RunControl

  @allowed_tools MapSet.new([
                   "executor_status",
                   "list_dir",
                   "memory_status",
                   "read",
                   "skill_discover",
                   "skill_get",
                   "tool_list",
                   "web_fetch",
                   "web_search"
                 ])

  @type owner_snapshot :: RunControl.Run.t()

  @spec allowed_tool_definition?(map()) :: boolean()
  def allowed_tool_definition?(definition) when is_map(definition) do
    name = Map.get(definition, "name") || Map.get(definition, :name) || ""
    MapSet.member?(@allowed_tools, to_string(name))
  end

  def allowed_tool_definition?(_definition), do: false

  @spec render_status(owner_snapshot()) :: String.t()
  def render_status(%RunControl.Run{} = run) do
    elapsed_seconds = max(div(System.system_time(:millisecond) - run.started_at_ms, 1000), 0)
    tool = if run.current_tool, do: run.current_tool, else: "-"
    partial = present_tail(run.latest_assistant_partial)
    tool_tail = present_tail(run.latest_tool_output_tail)

    """
    Status: #{run.status}
    Phase: #{run.current_phase}
    Tool: #{tool}
    Elapsed: #{elapsed_seconds}s
    Queued: #{run.queued_count}
    Assistant partial: #{partial}
    Tool output tail: #{tool_tail}
    """
    |> String.trim()
  end

  @spec render_busy_follow_up(owner_snapshot(), String.t()) :: String.t()
  def render_busy_follow_up(%RunControl.Run{} = run, question) when is_binary(question) do
    condensed_question =
      question
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    base =
      "Owner run is still #{run.status}. Phase=#{run.current_phase}, tool=#{run.current_tool || "-"}, queued=#{run.queued_count}."

    case condensed_question do
      "" ->
        base <> " " <> render_tail_sentence(run)

      _ ->
        base <> " Follow-up: #{condensed_question}. " <> render_tail_sentence(run)
    end
  end

  defp render_tail_sentence(%RunControl.Run{} = run) do
    cond do
      present?(run.latest_tool_output_tail) ->
        "Latest tool output: #{present_tail(run.latest_tool_output_tail)}"

      present?(run.latest_assistant_partial) ->
        "Latest assistant partial: #{present_tail(run.latest_assistant_partial)}"

      true ->
        "No shareable partial output yet."
    end
  end

  defp present?(text) when is_binary(text), do: String.trim(text) != ""
  defp present?(_text), do: false

  defp present_tail(text) when is_binary(text) do
    text
    |> String.trim()
    |> case do
      "" -> "-"
      value -> value
    end
  end

  defp present_tail(_text), do: "-"
end
