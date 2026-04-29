defmodule Nex.Agent.ChannelSpecTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Interface.Channel.Catalog
  alias Nex.Agent.Interface.Channel.Specs.{Discord, Feishu}
  alias Nex.Agent.Runtime.Config

  test "catalog exposes only implemented channel specs" do
    assert Catalog.types() == ["feishu", "discord"]
    assert Catalog.fetch(:feishu) == {:ok, Feishu}
    assert Catalog.fetch("discord") == {:ok, Discord}
    assert {:error, {:unknown_channel_type, "telegram"}} = Catalog.fetch("telegram")
  end

  test "disabled channel plugin removes the channel type from catalog projection" do
    config = Config.from_map(%{"plugins" => %{"disabled" => ["builtin:channel.discord"]}})

    assert Catalog.types(config: config) == ["feishu"]
    assert Catalog.fetch("feishu", config: config) == {:ok, Feishu}
    assert {:error, {:unknown_channel_type, "discord"}} = Catalog.fetch("discord", config: config)
  end

  test "fetch bang raises a clear unknown channel error" do
    assert_raise ArgumentError, ~s(unknown channel type: "telegram"), fn ->
      Catalog.fetch!("telegram")
    end
  end

  test "feishu spec owns runtime, prompt, gateway, profile, renderer, and config contract" do
    instance =
      Feishu.apply_defaults(%{"enabled" => true, "app_id" => "cli", "app_secret" => "secret"})

    assert :ok = Feishu.validate_instance(instance, instance_id: "feishu_main")
    assert Feishu.runtime(instance) == %{"type" => "feishu", "streaming" => true}
    refute Map.has_key?(Feishu.runtime(instance), "app_secret")
    assert Feishu.gateway_module() == Nex.Agent.Channel.Feishu
    assert Feishu.im_profile().name == :feishu
    assert Feishu.renderer() == Nex.Agent.Interface.IMIR.Renderers.Feishu

    prompt = Feishu.format_prompt(Feishu.runtime(instance), [])
    assert prompt =~ "## Feishu Output Contract"
    assert prompt =~ "Feishu markdown-like text IR"

    contract = Feishu.config_contract()
    assert contract["defaults"]["streaming"] == true
    assert "app_secret" in contract["secret_fields"]
    assert "app_secret" in contract["required_when_enabled"]
    assert "encrypt_key" in contract["secret_fields"]
    refute "encrypt_key" in contract["required_when_enabled"]
  end

  test "discord spec owns runtime, prompt, gateway, profile, renderer, and config contract" do
    instance =
      Discord.apply_defaults(%{
        "enabled" => true,
        "token" => "discord-token",
        "show_table_as" => "EMBED"
      })

    assert :ok = Discord.validate_instance(instance, instance_id: "discord_main")

    assert Discord.runtime(instance) == %{
             "type" => "discord",
             "streaming" => false,
             "show_table_as" => "embed"
           }

    refute Map.has_key?(Discord.runtime(instance), "token")
    assert Discord.gateway_module() == Nex.Agent.Channel.Discord
    assert Discord.im_profile().name == :discord
    assert Discord.renderer() == Nex.Agent.Interface.IMIR.Renderers.Discord

    prompt = Discord.format_prompt(Discord.runtime(instance), [])
    assert prompt =~ "## Discord Output Contract"
    assert prompt =~ "bold standalone labels"
    assert prompt =~ "####"
    assert prompt =~ "Never output separator or horizontal-rule lines"
    assert prompt =~ "Markdown tables render as embed"

    contract = Discord.config_contract()
    assert contract["defaults"]["streaming"] == false
    assert contract["defaults"]["show_table_as"] == "ascii"
    assert contract["options"]["show_table_as"] == ["raw", "ascii", "embed"]
    assert contract["secret_fields"] == ["token"]
    assert contract["required_when_enabled"] == ["token"]
  end

  test "enabled channel requirements return structured diagnostics" do
    assert {:error, [diagnostic]} =
             Discord.validate_instance(Discord.apply_defaults(%{"enabled" => true}),
               instance_id: "discord_main"
             )

    assert diagnostic.code == :missing_required_channel_field
    assert diagnostic.field == "token"
    assert diagnostic.instance_id == "discord_main"

    assert {:error, diagnostics} =
             Feishu.validate_instance(Feishu.apply_defaults(%{"enabled" => true}),
               instance_id: "feishu_main"
             )

    assert Enum.map(diagnostics, & &1.field) == ["app_id", "app_secret"]
  end
end
