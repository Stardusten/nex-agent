defmodule Nex.Agent.SandboxFileIOInventoryTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  @migrated_paths [
    "lib/nex/agent/capability/tool/core/read.ex",
    "lib/nex/agent/capability/tool/core/find.ex",
    "lib/nex/agent/capability/tool/core/apply_patch.ex",
    "lib/nex/agent/capability/tool/core/message.ex",
    "lib/nex/agent/capability/tool/core/user_update.ex",
    "lib/nex/agent/capability/tool/core/soul_update.ex",
    "priv/plugins/builtin/tool.memory/lib/nex/agent/tool/memory_write.ex",
    "priv/plugins/builtin/channel.feishu/lib/nex/agent/channel/feishu.ex"
  ]

  test "migrated user-controlled file tool paths do not call File directly" do
    hits =
      @migrated_paths
      |> Enum.flat_map(fn relative ->
        @root
        |> Path.join(relative)
        |> file_hits(relative)
      end)

    assert hits == []
  end

  defp file_hits(path, relative) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      if line =~
           ~r/File\.(read|read!|write|write!|stream!|ls|stat|regular\?|dir\?|exists\?|rm|rm_rf|mkdir_p|mkdir_p!)/ do
        [%{path: relative, line: line_no, text: String.trim(line)}]
      else
        []
      end
    end)
  end
end
