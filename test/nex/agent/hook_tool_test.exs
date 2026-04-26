defmodule Nex.Agent.HookToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Hooks, Runtime}
  alias Nex.Agent.Tool.Hook

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-hook-tool-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "KB.md"), "# KB\n")

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace, kb_file: Path.join(workspace, "KB.md")}
  end

  test "add_file writes registry and test matches current session", %{
    workspace: workspace,
    kb_file: file
  } do
    ctx = %{workspace: workspace, session_key: "discord:kb", channel: "discord", chat_id: "kb"}

    assert {:ok, %{"status" => "saved", "hook" => hook}} =
             Hook.execute(
               %{
                 "action" => "add_file",
                 "id" => "kb-file",
                 "session" => "discord:kb",
                 "path" => file,
                 "title" => "KB File",
                 "priority" => 10
               },
               ctx
             )

    assert hook["pointcut"]["session"] == "discord:kb"
    assert File.exists?(Hooks.registry_path(workspace: workspace))

    assert {:ok, %{"matched" => true, "fragment_count" => 1, "fragments" => [fragment]}} =
             Hook.execute(%{"action" => "test", "id" => "kb-file"}, ctx)

    assert fragment["id"] == "kb-file"
    assert fragment["source"] == file
  end

  test "add_text enable disable remove and show", %{workspace: workspace} do
    ctx = %{workspace: workspace, session_key: "discord:kb", channel: "discord", chat_id: "kb"}
    content = "  Bare links are ingest requests.\n"

    assert {:ok, %{"status" => "saved"}} =
             Hook.execute(
               %{
                 "action" => "add_text",
                 "id" => "kb-thread",
                 "session" => "discord:kb",
                 "content" => content,
                 "title" => "KB Thread"
               },
               ctx
             )

    assert {:ok,
            %{
              "id" => "kb-thread",
              "enabled" => true,
              "advice" => %{"content" => ^content}
            }} =
             Hook.execute(%{"action" => "show", "id" => "kb-thread"}, ctx)

    assert {:ok, %{"status" => "disabled", "hook" => %{"enabled" => false}}} =
             Hook.execute(%{"action" => "disable", "id" => "kb-thread"}, ctx)

    assert {:ok, %{"matched" => false}} =
             Hook.execute(%{"action" => "test", "id" => "kb-thread"}, ctx)

    assert {:ok, %{"status" => "enabled", "hook" => %{"enabled" => true}}} =
             Hook.execute(%{"action" => "enable", "id" => "kb-thread"}, ctx)

    assert {:ok, %{"matched" => true}} =
             Hook.execute(%{"action" => "test", "id" => "kb-thread"}, ctx)

    assert {:ok, %{"status" => "removed", "id" => "kb-thread"}} =
             Hook.execute(%{"action" => "remove", "id" => "kb-thread"}, ctx)

    assert {:error, "Hook not found: kb-thread"} =
             Hook.execute(%{"action" => "show", "id" => "kb-thread"}, ctx)
  end

  test "mutation triggers runtime reload when runtime is available", %{
    workspace: workspace,
    kb_file: file
  } do
    before_version =
      case Runtime.current() do
        {:ok, snapshot} -> snapshot.version
        {:error, :runtime_unavailable} -> nil
      end

    assert {:ok, %{"status" => "saved"}} =
             Hook.execute(
               %{
                 "action" => "add_file",
                 "id" => "kb-file",
                 "session" => "discord:kb",
                 "path" => file
               },
               %{workspace: workspace, session_key: "discord:kb"}
             )

    assert Hooks.load(workspace: workspace).entries
           |> Enum.any?(&(Map.get(&1, "id") == "kb-file"))

    if before_version do
      assert {:ok, snapshot} = Runtime.current()
      assert snapshot.workspace == workspace
      assert snapshot.version > before_version
    end
  end

  test "mutation returns error when runtime reload fails", %{workspace: workspace} do
    ctx = %{
      workspace: workspace,
      session_key: "discord:kb",
      runtime_reload_fun: fn _opts -> {:error, :boom} end
    }

    assert {:error, message} =
             Hook.execute(
               %{
                 "action" => "add_text",
                 "id" => "reload-fail",
                 "session" => "discord:kb",
                 "content" => "saved but not active"
               },
               ctx
             )

    assert message =~ "hook registry saved but runtime reload failed"

    assert Hooks.load(workspace: workspace).entries
           |> Enum.any?(&(Map.get(&1, "id") == "reload-fail"))
  end
end
