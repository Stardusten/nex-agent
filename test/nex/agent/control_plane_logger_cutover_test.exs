defmodule Nex.Agent.ControlPlaneLoggerCutoverTest do
  use ExUnit.Case, async: true

  @projection_or_boundary_files MapSet.new([
                          "lib/nex/agent/admin.ex",
                          "lib/nex/agent/channel/discord.ex",
                          "lib/nex/agent/channel/discord/stream_converter.ex",
                          "lib/nex/agent/channel/discord/ws_client.ex",
                          "lib/nex/agent/channel/feishu.ex",
                          "lib/nex/agent/channel/feishu/stream_converter.ex",
                          "lib/nex/agent/channel/feishu/ws_client.ex",
                          "lib/nex/agent/context_builder.ex",
                          "lib/nex/agent/control_plane/log.ex",
                          "lib/nex/agent/cron.ex",
                          "lib/nex/agent/gateway.ex",
                          "lib/nex/agent/heartbeat.ex",
                          "lib/nex/agent/hot_reload.ex",
                          "lib/nex/agent/llm/req_llm.ex",
                          "lib/nex/agent/mcp.ex",
                          "lib/nex/agent/mcp/discovery.ex",
                          "lib/nex/agent/mcp/server_manager.ex",
                          "lib/nex/agent/media/hydrator.ex",
                          "lib/nex/agent/onboarding.ex",
                          "lib/nex/agent/run_control.ex",
                          "lib/nex/agent/runtime.ex",
                          "lib/nex/agent/runtime/reconciler.ex",
                          "lib/nex/agent/runtime/watcher.ex",
                          "lib/nex/agent/self_healing/router.ex",
                          "lib/nex/agent/self_update/deployer.ex",
                          "lib/nex/agent/session_manager.ex",
                          "lib/nex/agent/subagent.ex",
                          "lib/nex/agent/tool/custom_tools.ex",
                          "lib/nex/agent/tool/message.ex",
                          "lib/nex/agent/tool/registry.ex"
                        ])

  @allowed_logger_call_patterns %{
    "lib/nex/agent/runner.ex" => [
      ~r/control-plane log .* failed/,
      ~r/control-plane log .* returned/,
      ~r/control-plane log .* crashed/
    ],
    "lib/nex/agent/inbound_worker.ex" => [
      ~r/Dropping stale async success/,
      ~r/Dropping stale async error/,
      ~r/Dropping stale async failure/,
      ~r/Task .* timed out/,
      ~r/Follow-up task .* exited/,
      ~r/Task process .* crashed/,
      ~r/Cleaning up .* stale agent session/,
      ~r/stream event failed/,
      ~r/stream flush failed/,
      ~r/InboundWorker received/,
      ~r/Draining queued message/,
      ~r/Rebuilding stale agent/,
      ~r/creating new agent session/,
      ~r/publishing topic=/,
      ~r/Suppressed stage-direction output/,
      ~r/stream finalize failed/,
      ~r/stream flush before finalize failed/,
      ~r/observation failed/,
      ~r/\[FeishuStream\]/
    ]
  }

  test "direct Logger usage stays inside the reviewed 13D allowlist" do
    violations =
      Path.wildcard("lib/nex/agent/**/*.ex")
      |> Enum.flat_map(&logger_violations/1)

    assert violations == []
  end

  defp logger_violations(path) do
    lines = path |> File.read!() |> String.split("\n")

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_no} -> String.contains?(line, "Logger.") end)
    |> Enum.reject(fn {_line, line_no} -> allowed_logger_call?(path, lines, line_no) end)
    |> Enum.map(fn {line, line_no} -> "#{path}:#{line_no}: #{String.trim(line)}" end)
  end

  defp allowed_logger_call?(path, lines, line_no) do
    MapSet.member?(@projection_or_boundary_files, path) or
      path
      |> allowed_patterns()
      |> Enum.any?(&Regex.match?(&1, logger_call_context(lines, line_no)))
  end

  defp allowed_patterns(path), do: Map.get(@allowed_logger_call_patterns, path, [])

  defp logger_call_context(lines, line_no) do
    lines
    |> Enum.slice(line_no - 1, 5)
    |> Enum.join("\n")
  end
end
