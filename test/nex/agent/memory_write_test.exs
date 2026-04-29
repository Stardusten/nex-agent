defmodule Nex.Agent.Knowledge.MemoryWriteTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{App.Bus, Knowledge.Memory}
  alias Nex.Agent.Tool.MemoryWrite

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-memory-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Long-term Memory\n")
    Application.put_env(:nex_agent, :workspace_path, workspace)
    start_or_restart_supervised!({Bus, name: Bus})

    on_exit(fn ->
      Application.delete_env(:nex_agent, :workspace_path)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "memory_write writes MEMORY.md", %{workspace: workspace} do
    assert {:ok, _} =
             MemoryWrite.execute(
               %{
                 "action" => "append",
                 "content" => "Project uses OTP supervision."
               },
               %{workspace: workspace}
             )

    assert Memory.read_long_term(workspace: workspace) =~ "Project uses OTP supervision."
  end

  test "memory_write set replaces full memory and append adds content", %{workspace: workspace} do
    :ok =
      Memory.write_long_term("# Long-term Memory\n\nTech stack: Elixir/OTP\n",
        workspace: workspace
      )

    assert {:ok, _} =
             MemoryWrite.execute(
               %{
                 "action" => "set",
                 "content" => "# Long-term Memory\n\nTech stack: Elixir/OTP with Phoenix\n"
               },
               %{workspace: workspace}
             )

    assert Memory.read_long_term(workspace: workspace) =~ "Phoenix"

    assert {:ok, _} =
             MemoryWrite.execute(
               %{
                 "action" => "append",
                 "content" => "Deployment: fly.io"
               },
               %{workspace: workspace}
             )

    assert Memory.read_long_term(workspace: workspace) =~ "Deployment: fly.io"
  end

  test "memory_write publishes notice when a user-visible tool call changes memory", %{
    workspace: workspace
  } do
    topic = {:channel_outbound, "feishu_memory_write"}
    Bus.subscribe(topic)
    on_exit(fn -> if Process.whereis(Bus), do: Bus.unsubscribe(topic) end)

    assert {:ok, _} =
             MemoryWrite.execute(
               %{
                 "action" => "append",
                 "content" => "Project uses OTP supervision."
               },
               %{
                 workspace: workspace,
                 channel: "feishu_memory_write",
                 chat_id: "chat-write",
                 session_key: "feishu_memory_write:chat-write",
                 provider: :ollama,
                 model: "local-test"
               }
             )

    assert_receive {:bus_message, ^topic, payload}, 1_000
    assert payload.chat_id == "chat-write"
    assert payload.content == "🧠 Memory - Project uses OTP supervision."
    assert payload.metadata["_memory_notice"] == true
  end

  defp start_or_restart_supervised!(child_spec) do
    case start_supervised(child_spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
