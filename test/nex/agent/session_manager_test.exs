defmodule Nex.Agent.Conversation.SessionManagerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Conversation.Session, Conversation.SessionManager}

  test "same session key stays isolated across workspaces" do
    if Process.whereis(SessionManager) == nil do
      start_supervised!({SessionManager, name: SessionManager})
    end

    workspace_a =
      Path.join(System.tmp_dir!(), "nex-agent-session-a-#{System.unique_integer([:positive])}")

    workspace_b =
      Path.join(System.tmp_dir!(), "nex-agent-session-b-#{System.unique_integer([:positive])}")

    key = "shared-session"

    on_exit(fn ->
      SessionManager.invalidate(key, workspace: workspace_a)
      SessionManager.invalidate(key, workspace: workspace_b)
      File.rm_rf!(workspace_a)
      File.rm_rf!(workspace_b)
    end)

    session_a =
      Session.new(key)
      |> Session.add_message("user", "from workspace a")

    session_b =
      Session.new(key)
      |> Session.add_message("user", "from workspace b")

    :ok = Session.save(session_a, workspace: workspace_a)
    :ok = Session.save(session_b, workspace: workspace_b)

    assert SessionManager.get_or_create(key, workspace: workspace_a).messages
           |> hd()
           |> Map.get("content") ==
             "from workspace a"

    assert SessionManager.get_or_create(key, workspace: workspace_b).messages
           |> hd()
           |> Map.get("content") ==
             "from workspace b"
  end
end
