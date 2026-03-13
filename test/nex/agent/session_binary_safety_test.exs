defmodule Nex.Agent.SessionBinarySafetyTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Session

  test "session save handles binary content safely" do
    key = "binary-safe:#{System.unique_integer([:positive])}"

    session =
      Session.new(key)
      |> Session.add_message("tool", <<0x1F, 0x8B, 0x08, 0x00>>)

    session_dir =
      Path.join([
        System.get_env("HOME", "~"),
        ".nex/agent/workspace/sessions",
        String.replace(key, ":", "_")
      ])

    on_exit(fn -> File.rm_rf!(session_dir) end)

    assert :ok = Session.save(session)

    loaded = Session.load(key)
    content = hd(loaded.messages)["content"]

    assert is_binary(content)
    assert String.valid?(content)
    assert content =~ "Binary output"
  end
end
