defmodule Nex.Agent.PermissionRuleDebugToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Capability.Tool.Core.{AddPermissionRule, PermissionRuleDebug}
  alias Nex.Agent.Sandbox.Approval

  test "debug reports current approved command rule and uncovered path requirement" do
    %{ctx: ctx, workspace: workspace, root: root, server: server} = fixture()

    approve_session_rule(ctx, workspace, server, %{
      "resource" => "command",
      "command_prefix" => "ls",
      "requested_execution" => "sandboxed",
      "scope" => "thread",
      "persistence" => "session",
      "reason" => "Allow ls commands in this thread"
    })

    assert {:ok, result} =
             PermissionRuleDebug.execute(%{"event" => %{"command" => "ls #{root}"}}, ctx)

    current = result.current_decision
    assert current.action == "ask"
    assert current.hint =~ "path requirement"

    assert Enum.any?(
             current.requirements,
             &(&1.resource == "command" and &1.operation == "execute" and &1.action == "allow")
           )

    assert Enum.any?(
             current.uncovered_requirements,
             &(&1.resource == "path" and &1.operation == "list")
           )
  end

  test "debug evaluates candidate-only and combined rule coverage" do
    %{ctx: ctx, workspace: workspace, root: root, server: server} = fixture()

    approve_session_rule(ctx, workspace, server, %{
      "resource" => "command",
      "command_prefix" => "ls",
      "requested_execution" => "sandboxed",
      "scope" => "thread",
      "persistence" => "session",
      "reason" => "Allow ls commands in this thread"
    })

    assert {:ok, result} =
             PermissionRuleDebug.execute(
               %{
                 "event" => %{"command" => "ls #{root}"},
                 "candidate_rule" => %{
                   "resource" => "path",
                   "path_under" => root,
                   "operations" => ["list"],
                   "scope" => "thread"
                 }
               },
               ctx
             )

    assert result.current_decision.action == "ask"
    assert result.candidate_only_decision.action == "ask"
    assert result.candidate_only_decision.hint =~ "command:execute"
    assert result.combined_decision.action == "allow"
    assert result.combined_decision.uncovered_requirements == []
  end

  defp approve_session_rule(ctx, workspace, server, args) do
    task = Task.async(fn -> AddPermissionRule.execute(args, ctx) end)

    wait_until(fn ->
      Approval.pending?(workspace, "discord:thread-1", server: server)
    end)

    assert {:ok, %{approved: 1, choice: :session}} =
             Approval.approve(workspace, "discord:thread-1", :session, server: server)

    assert {:ok, %{status: :approved}} = Task.await(task, 1_000)
  end

  defp fixture do
    workspace = tmp_dir("workspace")
    root = tmp_dir("desktop")
    server = Module.concat(__MODULE__, :"Approval#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.mkdir_p!(root)
    start_supervised!({Approval, name: server})

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(root)
    end)

    %{
      workspace: workspace,
      root: root,
      server: server,
      ctx: %{
        workspace: workspace,
        cwd: workspace,
        session_key: "discord:thread-1",
        channel: "discord",
        chat_id: "thread-1",
        approval_server: server
      }
    }
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition was not met")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp tmp_dir(label) do
    Path.join(
      System.tmp_dir!(),
      "nex-agent-rule-debug-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
