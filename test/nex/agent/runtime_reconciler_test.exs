defmodule Nex.Agent.RuntimeReconcilerTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Config, Gateway, Runtime}

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "nex-agent-reconciler-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "# AGENTS\n")
    File.write!(Path.join(workspace, "SOUL.md"), "# SOUL\n")
    File.write!(Path.join(workspace, "USER.md"), "# USER\n")
    File.write!(Path.join(workspace, "TOOLS.md"), "# TOOLS\n")
    File.write!(Path.join(workspace, "memory/MEMORY.md"), "# Memory\n")

    if Process.whereis(Nex.Agent.Bus) == nil do
      start_supervised!({Nex.Agent.Bus, name: Nex.Agent.Bus})
    end

    if Process.whereis(Nex.Agent.ChannelSupervisor) == nil do
      start_supervised!(
        {DynamicSupervisor, name: Nex.Agent.ChannelSupervisor, strategy: :one_for_one}
      )
    end

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

      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "gateway reconcile enables and disables channel child locally", %{workspace: workspace} do
    disabled_config = %Config{Config.default() | telegram: %{"enabled" => false}}
    enabled_config = %Config{Config.default() | telegram: %{"enabled" => true, "token" => ""}}

    {:ok, _snapshot} =
      Runtime.reload(
        workspace: workspace,
        config_loader: fn _opts -> disabled_config end
      )

    :sys.replace_state(Process.whereis(Gateway), fn state ->
      %{state | status: :running, config: disabled_config}
    end)

    assert :ok = Gateway.reconcile()
    assert Process.whereis(Nex.Agent.Channel.Telegram) == nil

    {:ok, _snapshot} =
      Runtime.reload(
        workspace: workspace,
        config_loader: fn _opts -> enabled_config end,
        changed_paths: ["config.json"]
      )

    assert :ok = Gateway.reconcile()
    assert is_pid(Process.whereis(Nex.Agent.Channel.Telegram))

    {:ok, _snapshot} =
      Runtime.reload(
        workspace: workspace,
        config_loader: fn _opts -> disabled_config end,
        changed_paths: ["config.json"]
      )

    assert :ok = Gateway.reconcile()
    assert Process.whereis(Nex.Agent.Channel.Telegram) == nil
  end
end
