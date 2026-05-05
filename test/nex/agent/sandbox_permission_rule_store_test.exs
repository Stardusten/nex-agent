defmodule Nex.Agent.SandboxPermissionRuleStoreTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Sandbox.PermissionRule
  alias Nex.Agent.Sandbox.PermissionRule.Rule
  alias Nex.Agent.Sandbox.PermissionRuleStore

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-rule-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "saves and loads a hash-chain rule store", %{workspace: workspace} do
    rule = allow_rule("allow-dokobot-get", {:prefix, :command_tokens, ["dokobot", "get"]})

    assert :ok = PermissionRuleStore.save(workspace, [rule])
    assert {:ok, [loaded]} = PermissionRuleStore.load(workspace)

    assert loaded.effect == :allow
    assert {:prefix, :command_tokens, ["dokobot", "get"]} in loaded.predicates
    assert PermissionRule.grant_key(loaded) == PermissionRule.grant_key(rule)

    paths = PermissionRuleStore.paths(workspace)
    assert File.exists?(paths.chain)
    assert File.exists?(paths.manifest)
  end

  test "detects tampered rule chain content and returns valid prefix", %{workspace: workspace} do
    first = allow_rule("allow-dokobot", {:prefix, :command_tokens, ["dokobot"]})
    second = allow_rule("allow-rg", {:prefix, :command_tokens, ["rg"]})

    assert :ok = PermissionRuleStore.save(workspace, [first, second])

    paths = PermissionRuleStore.paths(workspace)

    paths.chain
    |> File.read!()
    |> String.replace("allow-rg", "allow-rm")
    |> then(&File.write!(paths.chain, &1))

    assert {:error, {:tampered, {:bad_hash, 2}}, [valid_prefix]} =
             PermissionRuleStore.load(workspace)

    assert valid_prefix.id == "allow-dokobot"
  end

  defp allow_rule(id, predicate) do
    Rule.new(
      id: id,
      effect: :allow,
      scope: :thread,
      predicates: [
        {:eq, :channel, "discord"},
        {:eq, :chat_id, "thread-1"},
        predicate
      ]
    )
  end
end
