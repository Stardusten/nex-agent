defmodule Nex.Agent.SandboxProcessInventoryTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  @allowed %{
    "lib/nex/agent/sandbox/exec.ex" => ~r/Port\.open/,
    "lib/nex/agent/observe/admin.ex" => ~r/System\.cmd\("kill"/,
    "lib/mix/tasks/nex.agent.ex" => ~r/System\.cmd\("kill"/
  }

  test "production child process creation is centralized in Sandbox.Exec with reviewed exemptions" do
    hits =
      ["lib/**/*.ex", "priv/plugins/builtin/**/*.ex"]
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
      |> Enum.flat_map(&process_hits/1)
      |> Enum.reject(&allowed_hit?/1)

    assert hits == []
  end

  defp process_hits(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      if line =~ ~r/System\.cmd|Port\.open|:os\.cmd/ do
        [%{path: relative(path), line: line_no, text: String.trim(line)}]
      else
        []
      end
    end)
  end

  defp allowed_hit?(%{path: path, text: text}) do
    case Map.get(@allowed, path) do
      nil -> false
      regex -> text =~ regex
    end
  end

  defp relative(path), do: Path.relative_to(path, @root)
end
