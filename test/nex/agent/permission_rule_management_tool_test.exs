defmodule Nex.Agent.PermissionRuleManagementToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Capability.Tool.Core.{
    AddPermissionRule,
    PermissionListRules,
    PermissionRevokeRule,
    PermissionRuleDebug
  }

  alias Nex.Agent.Sandbox.Approval

  test "list exposes semantic rule refs and revoke removes a session allow rule" do
    %{ctx: ctx, workspace: workspace, root: root, server: server} = fixture()

    approve_session_rule(ctx, workspace, server, %{
      "resource" => "command",
      "command_prefix" => "ls",
      "requested_execution" => "sandboxed",
      "scope" => "thread",
      "persistence" => "session",
      "reason" => "Allow ls commands in this thread"
    })

    assert {:ok, listed} = PermissionListRules.execute(%{}, ctx)
    assert listed.count == 1
    assert [rule] = listed.rules
    assert rule.resource == "command"
    assert rule.persistence == "session"
    assert rule.removable? == true
    assert rule.match =~ "command prefix `ls ...`"
    assert is_binary(rule.rule_ref)

    assert {:ok, revoked} =
             PermissionRevokeRule.execute(
               %{"rule_ref" => rule.rule_ref, "reason" => "No longer needed"},
               ctx
             )

    assert revoked.status == "revoked"
    assert revoked.revoked_rule.rule_ref == rule.rule_ref

    assert {:ok, listed_after} = PermissionListRules.execute(%{}, ctx)
    assert listed_after.rules == []

    assert {:ok, debugged} =
             PermissionRuleDebug.execute(%{"event" => %{"command" => "ls #{root}"}}, ctx)

    assert debugged.current_decision.action == "ask"

    assert Enum.any?(
             debugged.current_decision.uncovered_requirements,
             &(&1.resource == "command" and &1.operation == "execute")
           )
  end

  test "revoke removes a durable allow rule from the current permission state" do
    %{ctx: ctx, workspace: workspace, root: root, server: server} = fixture()

    approve_always_rule(ctx, workspace, server, %{
      "resource" => "path",
      "path_under" => root,
      "operations" => ["list"],
      "scope" => "thread",
      "persistence" => "always",
      "reason" => "Allow listing this tree in the thread"
    })

    assert {:ok, listed} = PermissionListRules.execute(%{"resource" => "path"}, ctx)
    assert [rule] = listed.rules
    assert rule.persistence == "always"
    assert rule.match =~ "path under #{root}"

    assert {:ok, _revoked} =
             PermissionRevokeRule.execute(%{"rule_ref" => rule.rule_ref}, ctx)

    assert {:ok, listed_after} = PermissionListRules.execute(%{"resource" => "path"}, ctx)
    assert listed_after.rules == []

    assert {:ok, debugged} =
             PermissionRuleDebug.execute(
               %{
                 "event" => %{
                   "tool_name" => "filesystem",
                   "path" => root,
                   "operation" => "list"
                 }
               },
               ctx
             )

    assert debugged.current_decision.action == "ask"
  end

  defp approve_session_rule(ctx, workspace, server, args) do
    approve_rule(ctx, workspace, server, args, :session)
  end

  defp approve_always_rule(ctx, workspace, server, args) do
    approve_rule(ctx, workspace, server, args, :always)
  end

  defp approve_rule(ctx, workspace, server, args, choice) do
    task = Task.async(fn -> AddPermissionRule.execute(args, ctx) end)

    wait_until(fn ->
      Approval.pending?(workspace, "discord:thread-1", server: server)
    end)

    assert {:ok, %{approved: 1, choice: ^choice}} =
             Approval.approve(workspace, "discord:thread-1", choice, server: server)

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
      "nex-agent-rule-management-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
