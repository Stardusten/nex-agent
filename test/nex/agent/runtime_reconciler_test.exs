defmodule Nex.Agent.RuntimeReconcilerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Runtime.Config, Interface.Gateway, Runtime}

  @feishu_instance "feishu_reconcile"
  @discord_instance "discord_reconcile"

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-reconciler-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    if Process.whereis(Nex.Agent.App.Bus) == nil do
      start_supervised!({Nex.Agent.App.Bus, name: Nex.Agent.App.Bus})
    end

    if Process.whereis(Nex.Agent.ChannelSupervisor) == nil do
      start_supervised!(
        {DynamicSupervisor, name: Nex.Agent.ChannelSupervisor, strategy: :one_for_one}
      )
    end

    if Process.whereis(Nex.Agent.ChannelRegistry) == nil do
      start_supervised!(Nex.Agent.Interface.Channel.Registry)
    end

    stop_channel_children()

    if Process.whereis(Runtime) == nil do
      start_supervised!({Runtime, workspace: workspace})
    else
      Runtime.reload(workspace: workspace)
    end

    if Process.whereis(Gateway) == nil do
      start_supervised!({Gateway, name: Gateway})
    end

    on_exit(fn ->
      if Process.whereis(Gateway) do
        _ = Gateway.stop()

        :sys.replace_state(Process.whereis(Gateway), fn state ->
          %{state | status: :stopped, config: Config.default(), started_at: nil}
        end)
      end

      stop_channel_children()
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "gateway reconcile starts, restarts, and removes channel instances", %{
    workspace: workspace
  } do
    disabled_config = config_with_channels(%{})

    enabled_config =
      config_with_channels(%{
        @feishu_instance => %{
          "type" => "feishu",
          "enabled" => true,
          "streaming" => true,
          "app_id" => "",
          "app_secret" => ""
        },
        @discord_instance => %{"type" => "discord", "enabled" => true, "token" => ""}
      })

    changed_config =
      config_with_channels(%{
        @feishu_instance => %{
          "type" => "feishu",
          "enabled" => true,
          "streaming" => false,
          "app_id" => "",
          "app_secret" => ""
        },
        @discord_instance => %{"type" => "discord", "enabled" => true, "token" => ""}
      })

    {:ok, _snapshot} =
      Runtime.reload(
        workspace: workspace,
        config_loader: fn _opts -> disabled_config end
      )

    :sys.replace_state(Process.whereis(Gateway), fn state ->
      %{state | status: :running, config: disabled_config}
    end)

    assert :ok = Gateway.reconcile()
    assert Nex.Agent.Interface.Channel.Registry.whereis(@feishu_instance) == nil
    assert Nex.Agent.Interface.Channel.Registry.whereis(@discord_instance) == nil

    {:ok, _snapshot} =
      Runtime.reload(
        workspace: workspace,
        config_loader: fn _opts -> enabled_config end,
        changed_paths: ["config.json"]
      )

    assert :ok = Gateway.reconcile()
    feishu_pid = Nex.Agent.Interface.Channel.Registry.whereis(@feishu_instance)
    discord_pid = Nex.Agent.Interface.Channel.Registry.whereis(@discord_instance)
    assert is_pid(feishu_pid)
    assert is_pid(discord_pid)

    {:ok, _snapshot} =
      Runtime.reload(
        workspace: workspace,
        config_loader: fn _opts -> changed_config end,
        changed_paths: ["config.json"]
      )

    assert :ok = Gateway.reconcile()
    assert Nex.Agent.Interface.Channel.Registry.whereis(@feishu_instance) != feishu_pid
    assert Nex.Agent.Interface.Channel.Registry.whereis(@discord_instance) == discord_pid

    {:ok, _snapshot} =
      Runtime.reload(
        workspace: workspace,
        config_loader: fn _opts -> disabled_config end,
        changed_paths: ["config.json"]
      )

    assert :ok = Gateway.reconcile()
    assert Nex.Agent.Interface.Channel.Registry.whereis(@feishu_instance) == nil
    assert Nex.Agent.Interface.Channel.Registry.whereis(@discord_instance) == nil
  end

  defp config_with_channels(channels) do
    %Config{
      Config.default()
      | channel: channels,
        provider: %{
          "providers" => %{
            "ollama-local" => %{
              "type" => "ollama",
              "base_url" => "http://localhost:11434"
            }
          }
        },
        model: %{
          "default_model" => "local-test",
          "cheap_model" => "local-test",
          "advisor_model" => "local-test",
          "models" => %{"local-test" => %{"provider" => "ollama-local", "id" => "local-test"}}
        }
    }
  end

  defp stop_channel_children do
    if Process.whereis(Nex.Agent.ChannelSupervisor) do
      Nex.Agent.ChannelSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Nex.Agent.ChannelSupervisor, pid)
      end)
    end
  end
end
