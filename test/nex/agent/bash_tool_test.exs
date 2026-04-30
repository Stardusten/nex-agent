defmodule Nex.Agent.BashToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Capability.Tool.Core.Bash
  alias Nex.Agent.Interface.Outbound.Action, as: OutboundAction
  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Sandbox.Approval

  setup do
    config =
      Config.from_map(%{
        "tools" => %{
          "sandbox" => %{
            "backend" => "noop",
            "approval" => %{"default" => "allow"}
          }
        }
      })

    {:ok, ctx: %{cwd: File.cwd!(), config: config}}
  end

  test "bash tool sanitizes non-utf8 command output", %{ctx: ctx} do
    assert {:ok, output} =
             Bash.execute(%{"command" => "printf '\\037\\213\\010\\000'", "timeout" => 2}, ctx)

    assert is_binary(output)
    assert String.valid?(output)
    assert output =~ "Binary output"
  end

  test "bash tool returns error for non-zero exit codes", %{ctx: ctx} do
    assert {:error, message} =
             Bash.execute(%{"command" => "exit 7", "timeout" => 1}, ctx)

    assert message =~ "Exit code 7"
  end

  test "bash tool honors timeout from tool arguments", %{ctx: ctx} do
    assert {:error, message} =
             Bash.execute(%{"command" => "sleep 1", "timeout" => 0.1}, ctx)

    assert message =~ "timed out"
  end

  test "bash requests approval and supports similar session grant" do
    parent = self()

    approval_server =
      String.to_atom("sandbox_bash_approval_#{System.unique_integer([:positive])}")

    start_supervised!({Approval, name: approval_server})

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-bash-approval-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(workspace) end)

    config =
      Config.from_map(%{
        "tools" => %{
          "sandbox" => %{
            "backend" => "noop",
            "approval" => %{"default" => "ask"}
          }
        }
      })

    stream_sink = fn event ->
      send(parent, {:stream_event, event})
      :ok
    end

    ctx = %{
      cwd: workspace,
      workspace: workspace,
      config: config,
      session_key: "feishu:bash-approval",
      channel: "feishu",
      chat_id: "bash-approval",
      approval_server: approval_server,
      stream_sink: stream_sink,
      tool_result_format: :envelope
    }

    task = Task.async(fn -> Bash.execute(%{"command" => "ls .", "timeout" => 2}, ctx) end)

    assert eventually(fn ->
             case Approval.pending(workspace, "feishu:bash-approval", server: approval_server) do
               [_request] -> true
               _ -> false
             end
           end)

    assert_receive {:stream_event, {:action, waiting_payload}}
    assert waiting_payload.content =~ "Approval required"
    assert waiting_payload.metadata["_nex_action"]["status"] == "waiting_approval"
    assert waiting_payload.metadata["_nex_action"]["subject"] == "ls ."

    assert {:ok, %{approved: 1, choice: :similar}} =
             Approval.approve(workspace, "feishu:bash-approval", :similar,
               server: approval_server
             )

    assert {:ok, %{content: output, metadata: metadata}} = Task.await(task, 1_000)
    refute output =~ "Sandbox approval:"
    assert get_in(metadata, ["sandbox", "approval_status"]) == "approved_after_request"
    assert get_in(metadata, ["sandbox", "llm_note"]) == "user approved before execution"

    assert {:ok, %{content: output, metadata: metadata}} =
             Bash.execute(%{"command" => "ls -la", "timeout" => 2}, ctx)

    refute output =~ "Sandbox approval:"
    assert get_in(metadata, ["sandbox", "approval_status"]) == "grant_allowed"
    assert get_in(metadata, ["sandbox", "llm_note"]) == "allowed by prior approval"

    assert_receive {:stream_event, {:action, allowed_payload}}
    assert allowed_payload.content == "⚙️ Bash - ls -la _(Allowed)_"
    assert OutboundAction.action(allowed_payload.metadata)["status"] == "allowed"

    refute Approval.pending?(workspace, "feishu:bash-approval", server: approval_server)
  end

  test "high-risk commands require approval even when sandbox default allows" do
    parent = self()

    approval_server =
      String.to_atom("sandbox_bash_risk_approval_#{System.unique_integer([:positive])}")

    start_supervised!({Approval, name: approval_server})

    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-bash-risk-approval-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "sample.txt"), "ok\n")
    on_exit(fn -> File.rm_rf!(workspace) end)

    config =
      Config.from_map(%{
        "tools" => %{
          "sandbox" => %{
            "backend" => "noop",
            "approval" => %{"default" => "allow"}
          }
        }
      })

    stream_sink = fn event ->
      send(parent, {:stream_event, event})
      :ok
    end

    ctx = %{
      cwd: workspace,
      workspace: workspace,
      config: config,
      session_key: "discord:bash-risk-approval",
      channel: "discord",
      chat_id: "bash-risk-approval",
      approval_server: approval_server,
      stream_sink: stream_sink,
      tool_result_format: :envelope
    }

    command = "D=$(pwd) && ls \"$D\""
    task = Task.async(fn -> Bash.execute(%{"command" => command, "timeout" => 2}, ctx) end)

    assert eventually(fn ->
             case Approval.pending(workspace, "discord:bash-risk-approval",
                    server: approval_server
                  ) do
               [_request] -> true
               _ -> false
             end
           end)

    assert_receive {:stream_event, {:action, waiting_payload}}
    assert waiting_payload.content =~ "Approval required"
    assert waiting_payload.content =~ "Risk: Command substitution runs a nested command"
    refute waiting_payload.content =~ "Allow similar"

    approval = waiting_payload.metadata["_nex_approval"]
    assert approval["risk_class"] == "command_substitution"
    assert approval["risk_hint"] =~ "nested command"
    refute Enum.any?(approval["actions"], &(&1["id"] == "approve_similar"))

    assert {:ok, %{approved: 1, choice: :once}} =
             Approval.approve(workspace, "discord:bash-risk-approval", :once,
               server: approval_server
             )

    assert {:ok, %{content: output, metadata: metadata}} = Task.await(task, 1_000)
    assert output =~ "sample.txt"
    assert get_in(metadata, ["sandbox", "approval_status"]) == "approved_after_request"
  end

  test "bash denies noninteractive approval-required commands" do
    config =
      Config.from_map(%{
        "tools" => %{
          "sandbox" => %{
            "backend" => "noop",
            "approval" => %{"default" => "ask"}
          }
        }
      })

    assert {:error, message} =
             Bash.execute(%{"command" => "ls .", "timeout" => 2}, %{
               cwd: File.cwd!(),
               config: config
             })

    assert message =~ "Sandbox approval required"
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
