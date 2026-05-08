defmodule Nex.Agent.SandboxPermissionRuleTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Sandbox.PermissionRule
  alias Nex.Agent.Sandbox.PermissionRule.Rule

  test "enriches raw command events inside the rule engine" do
    event =
      PermissionRule.enrich(%{
        channel: "discord",
        chat_id: "thread-1",
        command: "dokobot get https://example.com/a",
        requested_execution: :elevated
      })

    assert event.command_tokens == ["dokobot", "get", "https://example.com/a"]
    assert event.command_program == "dokobot"
    assert event.risk_class == :network_fetch
    assert event.inferred_network_hosts == ["example.com"]
    assert event.requested_execution == :elevated
    assert Enum.any?(event.requirements, &(&1.resource == :command and &1.operation == :execute))
    assert Enum.any?(event.requirements, &(&1.resource == :network and &1.operation == :connect))
  end

  test "enriches path tool events into path requirements" do
    event =
      PermissionRule.enrich(%{
        tool_name: "filesystem",
        params: %{"path" => "/tmp/nex-agent-permission/a.md", "operation" => "read"},
        channel: "discord",
        chat_id: "thread-1"
      })

    assert MapSet.member?(event.tags, :path)
    assert [%{resource: :path, operation: :read, target: target}] = event.requirements
    assert String.ends_with?(target, "/nex-agent-permission/a.md")
  end

  test "mcp rules normalize and match mcp requirements" do
    rule =
      rule("allow-mcp-connect",
        effect: :allow,
        predicates: [
          {:resource_eq, :mcp},
          {:operation_in, [:connect]},
          {:eq, :mcp_server, "echo_mcp"}
        ]
      )

    decision =
      PermissionRule.decide(
        %{
          tool_name: "mcp:connect:workspace:demo-echo:echo_mcp",
          workspace: "/tmp/nex-agent-workspace",
          metadata: %{
            "plugin_id" => "workspace:demo-echo",
            "mcp_server" => "echo_mcp",
            "mcp_operation" => "connect"
          }
        },
        [rule]
      )

    assert decision.action == :allow
    assert decision.winning_rule_id == "allow-mcp-connect"
    assert Enum.any?(decision.requirement_decisions, &(&1.requirement.resource == :mcp))
  end

  test "same level uses more specific matching rule before broader rule" do
    rules = [
      rule("global-rm-deny",
        effect: :deny,
        scope: :global,
        predicates: [{:prefix, :command_tokens, ["rm"]}]
      ),
      rule("thread-cache-allow",
        effect: :allow,
        scope: :thread,
        predicates: [
          {:eq, :channel, "discord"},
          {:eq, :chat_id, "thread-1"},
          {:exact, :command_tokens, ["rm", "-rf", "/tmp/cache"]}
        ]
      )
    ]

    decision =
      PermissionRule.decide(
        %{channel: "discord", chat_id: "thread-1", command: "rm -rf /tmp/cache"},
        rules
      )

    assert decision.action == :allow
    assert decision.winning_rule_id == "thread-cache-allow"
    assert decision.matched_rule_ids == ["global-rm-deny", "thread-cache-allow"]
  end

  test "higher level deny beats more specific lower level allow" do
    rules = [
      rule("thread-secret-allow",
        level: 0,
        effect: :allow,
        scope: :thread,
        predicates: [
          {:eq, :channel, "discord"},
          {:eq, :chat_id, "thread-1"},
          {:exact, :command_tokens, ["cat", "/secret"]}
        ]
      ),
      rule("system-secret-deny",
        level: 1,
        effect: :deny,
        scope: :global,
        predicates: [{:exact, :command_tokens, ["cat", "/secret"]}]
      )
    ]

    decision =
      PermissionRule.decide(
        %{channel: "discord", chat_id: "thread-1", command: "cat /secret"},
        rules
      )

    assert decision.action == :deny
    assert decision.winning_rule_id == "system-secret-deny"
  end

  test "same level and same specificity follows stricter decision" do
    rules = [
      rule("discord-allow", effect: :allow, predicates: [{:eq, :channel, "discord"}]),
      rule("thread-deny", effect: :deny, predicates: [{:eq, :chat_id, "thread-1"}])
    ]

    decision =
      PermissionRule.decide(
        %{channel: "discord", chat_id: "thread-1", command: "pwd"},
        rules
      )

    assert decision.action == :deny
    assert decision.winning_rule_id == "thread-deny"
  end

  test "longer command prefix is more specific inside the same level" do
    rules = [
      rule("dokobot-deny",
        effect: :deny,
        predicates: [{:prefix, :command_tokens, ["dokobot"]}]
      ),
      rule("dokobot-get-allow",
        effect: :allow,
        predicates: [{:prefix, :command_tokens, ["dokobot", "get"]}]
      )
    ]

    decision =
      PermissionRule.decide(
        %{command: "dokobot get https://example.com/a", requested_execution: :elevated},
        rules
      )

    assert decision.action == :allow
    assert decision.winning_rule_id == "dokobot-get-allow"
  end

  test "path_under rule allows path read descendants" do
    rule =
      rule("thread-desktop-read",
        effect: :allow,
        scope: :thread,
        predicates: [
          {:eq, :channel, "discord"},
          {:eq, :chat_id, "thread-1"},
          {:resource_eq, :path},
          {:operation_in, [:read, :list, :search, :stat, :stream]},
          {:path_under, "/tmp/nex-agent-desktop"}
        ]
      )

    decision =
      PermissionRule.decide(
        %{
          tool_name: "filesystem",
          params: %{"path" => "/tmp/nex-agent-desktop/project/a.md", "operation" => "read"},
          channel: "discord",
          chat_id: "thread-1"
        },
        [rule]
      )

    assert decision.action == :allow
    assert decision.winning_rule_id == "thread-desktop-read"
  end

  test "path rule alone does not allow bash read wrappers" do
    path_rule =
      rule("thread-desktop-read",
        effect: :allow,
        scope: :thread,
        predicates: [
          {:eq, :channel, "discord"},
          {:eq, :chat_id, "thread-1"},
          {:resource_eq, :path},
          {:operation_in, [:read, :list]},
          {:path_under, "/tmp/nex-agent-desktop"}
        ]
      )

    event = %{
      channel: "discord",
      chat_id: "thread-1",
      command: "ls /tmp/nex-agent-desktop/project"
    }

    enriched = PermissionRule.enrich(event)
    decision = PermissionRule.decide(event, [path_rule])

    assert Enum.any?(enriched.requirements, &(&1.resource == :command))
    assert Enum.any?(enriched.requirements, &(&1.resource == :path and &1.operation == :list))
    assert decision.action == :ask

    assert Enum.any?(
             decision.requirement_decisions,
             &(&1.requirement.resource == :command and &1.action == :ask)
           )

    assert Enum.any?(
             decision.requirement_decisions,
             &(&1.requirement.resource == :path and &1.action == :allow)
           )
  end

  test "event asks when a read path rule does not cover command execution semantics" do
    path_rule =
      rule("thread-desktop-read",
        effect: :allow,
        scope: :thread,
        predicates: [
          {:eq, :channel, "discord"},
          {:eq, :chat_id, "thread-1"},
          {:resource_eq, :path},
          {:operation_in, [:read]},
          {:path_under, "/tmp/nex-agent-desktop"}
        ]
      )

    decision =
      PermissionRule.decide(
        %{
          channel: "discord",
          chat_id: "thread-1",
          command: "cat /tmp/nex-agent-desktop/a.md | wc -l"
        },
        [path_rule]
      )

    assert decision.action == :ask
    assert Enum.any?(decision.requirement_decisions, &(&1.requirement.resource == :command))
    assert Enum.any?(decision.requirement_decisions, &(&1.requirement.resource == :path))
  end

  test "path read rule does not allow elevated bash execution" do
    path_rule =
      rule("thread-desktop-read",
        effect: :allow,
        scope: :thread,
        predicates: [
          {:eq, :channel, "discord"},
          {:eq, :chat_id, "thread-1"},
          {:resource_eq, :path},
          {:operation_in, [:read]},
          {:path_under, "/tmp/nex-agent-desktop"}
        ]
      )

    decision =
      PermissionRule.decide(
        %{
          channel: "discord",
          chat_id: "thread-1",
          command: "cat /tmp/nex-agent-desktop/a.md",
          requested_execution: :elevated
        },
        [path_rule]
      )

    assert decision.action == :ask
    assert Enum.any?(decision.requirement_decisions, &(&1.requirement.resource == :command))
  end

  test "path read rule does not allow bash write operations" do
    path_rule =
      rule("thread-desktop-read",
        effect: :allow,
        scope: :thread,
        predicates: [
          {:eq, :channel, "discord"},
          {:eq, :chat_id, "thread-1"},
          {:resource_eq, :path},
          {:operation_in, [:read]},
          {:path_under, "/tmp/nex-agent-desktop"}
        ]
      )

    decision =
      PermissionRule.decide(
        %{
          channel: "discord",
          chat_id: "thread-1",
          command: "touch /tmp/nex-agent-desktop/a.md"
        },
        [path_rule]
      )

    assert decision.action == :ask
    assert Enum.any?(decision.requirement_decisions, &(&1.requirement.resource == :command))

    assert Enum.any?(
             decision.requirement_decisions,
             &(&1.requirement.resource == :path and &1.requirement.operation == :write)
           )
  end

  test "bash path command grant option is command scoped instead of path scoped" do
    options =
      PermissionRule.grant_options(%{
        channel: "discord",
        chat_id: "thread-1",
        command: "ls /tmp/nex-agent-desktop/project"
      })

    assert [%{"level" => "exact", "subject" => subject, "rule" => rule}] = options
    assert subject =~ "Allow exact `ls /tmp/nex-agent-desktop/project` in this thread"

    predicate_ops = Enum.map(rule["predicates"], & &1["op"])
    assert "exact" in predicate_ops
    refute "path_under" in predicate_ops
  end

  test "rejects same predicate fingerprint with a conflicting decision" do
    existing =
      rule("allow-rg",
        effect: :allow,
        scope: :workspace,
        predicates: [{:prefix, :command_tokens, ["rg"]}]
      )

    conflicting =
      rule("deny-rg",
        effect: :deny,
        scope: :workspace,
        predicates: [{:prefix, :command_tokens, ["rg"]}]
      )

    duplicate =
      rule("allow-rg-duplicate",
        effect: :allow,
        scope: :workspace,
        predicates: [{:prefix, :command_tokens, ["rg"]}]
      )

    assert PermissionRule.validate_new_rule(conflicting, [existing]) ==
             {:error, {:conflicting_rule, "allow-rg"}}

    assert PermissionRule.validate_new_rule(duplicate, [existing]) == :ok
  end

  test "builds stable rule grant options from raw command events" do
    event = %{
      channel: "discord",
      chat_id: "thread-1",
      command: "dokobot get https://example.com/a",
      requested_execution: :elevated
    }

    options = PermissionRule.grant_options(event)

    assert [
             %{"level" => "exact", "grant_key" => exact_key},
             %{"level" => "similar", "grant_key" => similar_key}
           ] = options

    assert String.starts_with?(exact_key, "permission_rule:v2:")
    assert String.starts_with?(similar_key, "permission_rule:v2:")
    assert exact_key != similar_key

    assert PermissionRule.grant_options(%{event | command: "dokobot get https://example.com/b"})
           |> Enum.find(&(&1["level"] == "similar"))
           |> Map.fetch!("grant_key") == similar_key
  end

  defp rule(id, opts) do
    opts
    |> Keyword.put(:id, id)
    |> Rule.new()
  end
end
