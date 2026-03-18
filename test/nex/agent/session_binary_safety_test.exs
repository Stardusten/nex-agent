defmodule Nex.Agent.SessionBinarySafetyTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Session

  test "session save handles binary content safely" do
    key = "binary-safe:#{System.unique_integer([:positive])}"

    session =
      Session.new(key)
      |> Session.add_message("tool", <<0x1F, 0x8B, 0x08, 0x00>>)

    on_exit(fn -> File.rm_rf!(Session.session_dir(key)) end)

    assert :ok = Session.save(session)

    loaded = Session.load(key)
    content = hd(loaded.messages)["content"]

    assert is_binary(content)
    assert String.valid?(content)
    assert content =~ "Binary output"
  end

  test "session save respects configured workspace path" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-session-workspace-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:nex_agent, :workspace_path, workspace)

    key = "workspace-safe:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    assert :ok = Session.save(Session.new(key))
    assert File.exists?(Session.messages_path(key))
    assert String.starts_with?(Session.messages_path(key), Path.join(workspace, "sessions"))
  end
end
