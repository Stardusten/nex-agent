defmodule Nex.Agent.PluginTemplateTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Extension.Plugin.Template

  test "renders plugin config, secret, workspace, session, turn, and channel paths" do
    workspace = "/tmp/nex-agent-template-test"

    ctx = %{
      plugin_id: "workspace:memory",
      plugin_config: %{
        "endpoint" => "https://memory.example.test",
        "bank" => %{"template" => "nex-{{workspace.hash}}"}
      },
      secrets: %{"memory_api_token" => "super-secret-token"},
      workspace: workspace,
      session_key: "session:abc",
      turn_prompt: "hello",
      channel: "feishu",
      chat_id: "oc_123"
    }

    value = %{
      "url" => "{{plugin.config.endpoint}}/mcp",
      "authorization" => "Bearer {{secret.memory_api_token}}",
      "bank" => "{{plugin.config.bank.template}}",
      "session" => "{{session.key}}",
      "turn" => "{{turn.prompt}}",
      "channel_chat" => "{{channel}}:{{chat_id}}"
    }

    assert {:ok, %Template.Result{} = result} = Template.render_result(value, ctx)

    assert result.value["url"] == "https://memory.example.test/mcp"
    assert result.value["authorization"] == "Bearer super-secret-token"
    assert result.value["bank"] == "nex-#{workspace_hash(workspace)}"
    assert result.value["session"] == "session:abc"
    assert result.value["turn"] == "hello"
    assert result.value["channel_chat"] == "feishu:oc_123"

    assert Template.redacted_value(result)["authorization"] == "Bearer [REDACTED]"
    refute inspect(result.redactions) =~ "super-secret-token"
    assert [%{secret_id: "memory_api_token", replacement: "[REDACTED]"}] = result.redactions
  end

  test "does not support shell-style placeholder syntax" do
    assert {:ok, %Template.Result{value: "Bearer ${secret.foo}"}} =
             Template.render_result("Bearer ${secret.foo}", %{secrets: %{"foo" => "secret"}})
  end

  test "missing secret returns redacted error and render/2 keeps the original value" do
    template = "Bearer {{secret.missing}}"

    assert {:error, error} = Template.render_result(template, %{})
    assert error.code == :missing_secret
    assert error.secret_id == "missing"
    assert error.path == "secret.missing"
    assert Template.redacted_error(error).secret_id == "missing"
    assert Template.render(template, %{}) == template
  end

  defp workspace_hash(root) do
    :crypto.hash(:sha256, root)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end
end
