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
                 "interrupt_session",
                 "tool_list",
                 "web_fetch",
                 "web_search"
               ])

  @type owner_snapshot :: RunControl.Run.t()
  @type mode :: :busy | :idle

  @spec prompt(owner_snapshot() | nil, String.t(), keyword()) :: String.t()
  def prompt(owner_snapshot, question, opts \\ [])

  def prompt(%RunControl.Run{} = run, question, opts) when is_binary(question) do
    mode = Keyword.get(opts, :mode, :busy)

    """
    You are handling a short follow-up turn for a busy chat session.

    Hard rules:
    - You are not the owner run.
    - Do not modify or continue the owner's main task.
    - Do not claim you stopped anything unless you actually used the interrupt tool.
    - Keep the reply concise and directly answer the user's side question.
    - Only use tools exposed in this turn. They are read-only except a possible interrupt tool.
    - Use the interrupt tool only when the user clearly asks to stop, cancel, abort, or switch away from the current owner task.

    Session mode: #{mode}

    Owner snapshot:
    #{render_status(run)}

    User follow-up question:
    #{String.trim(question)}
    """
    |> String.trim()
  end

  def prompt(nil, question, opts) when is_binary(question) do
    mode = Keyword.get(opts, :mode, :idle)

    """
    You are handling a short side-question turn for a chat session with no active owner run.

    Hard rules:
    - There is no current owner run.
    - Answer the user's question directly and concisely.
    - Do not invent hidden state or claim a task is still running.
    - Only use tools exposed in this turn.

    Session mode: #{mode}

    User follow-up question:
    #{String.trim(question)}
    """
    |> String.trim()
  end

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
