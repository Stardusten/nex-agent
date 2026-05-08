defmodule Nex.Agent.SecretBaseTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.SecretBase

  setup do
    previous = System.get_env("NEX_AGENT_SECRET_BASE_TEST_TOKEN")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("NEX_AGENT_SECRET_BASE_TEST_TOKEN")
        value -> System.put_env("NEX_AGENT_SECRET_BASE_TEST_TOKEN", value)
      end
    end)

    :ok
  end

  test "resolves explicit test secret map" do
    assert {:ok, "test-secret"} =
             SecretBase.resolve("foo", %{secrets: %{"foo" => "test-secret"}})

    assert {:ok, "test-secret"} =
             SecretBase.resolve("foo", %{secrets: %{"foo" => %{"value" => "test-secret"}}})
  end

  test "resolves env secret declarations from normalized runtime config" do
    System.put_env("NEX_AGENT_SECRET_BASE_TEST_TOKEN", "env-secret")

    config =
      Config.from_map(%{
        "plugins" => %{
          "secrets" => %{
            "workspace:memory" => %{
              "memory_api_token" => %{"env" => "NEX_AGENT_SECRET_BASE_TEST_TOKEN"}
            }
          }
        }
      })

    assert {:ok, "env-secret"} =
             SecretBase.resolve("memory_api_token", %{
               config: config,
               plugin_id: "workspace:memory"
             })

    refute inspect(Config.plugins_runtime(config)) =~ "env-secret"
  end

  test "normalizes plugin secrets without preserving plaintext config values" do
    config =
      Config.from_map(%{
        "plugins" => %{
          "config" => %{"workspace:memory" => %{"endpoint" => "https://memory.example.test"}},
          "secrets" => %{
            "plain" => "must-not-be-preserved",
            "env_secret" => %{"env" => "NEX_AGENT_SECRET_BASE_TEST_TOKEN"}
          }
        }
      })

    plugins = Config.plugins_runtime(config)

    assert plugins["config"]["workspace:memory"]["endpoint"] == "https://memory.example.test"
    assert plugins["secrets"]["env_secret"] == %{"env" => "NEX_AGENT_SECRET_BASE_TEST_TOKEN"}
    refute Map.has_key?(plugins["secrets"], "plain")
    refute inspect(plugins) =~ "must-not-be-preserved"
  end

  test "missing secret returns a safe reason" do
    assert {:error, {:missing_secret, "missing"}} = SecretBase.resolve("missing", %{})
  end
end
