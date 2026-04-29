defmodule Nex.Agent.Plugin.CoreDependencyTest do
  use ExUnit.Case, async: true

  test "core lib modules do not directly reference builtin plugin modules" do
    repo_root = File.cwd!()
    plugin_modules = builtin_plugin_modules(repo_root)

    refs =
      for path <- Path.wildcard(Path.join([repo_root, "lib", "nex", "agent", "**", "*.ex"])),
          {:ok, source} = File.read(path),
          module <- plugin_modules,
          module_ref?(source, module) do
        "#{Path.relative_to(path, repo_root)} -> #{module}"
      end

    assert refs == [],
           "core must consume builtin plugins through catalog/registry/spec boundaries:\n" <>
             Enum.join(refs, "\n")
  end

  defp builtin_plugin_modules(repo_root) do
    repo_root
    |> Path.join("priv/plugins/builtin/**/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> then(&Regex.scan(~r/defmodule\s+([A-Z][A-Za-z0-9_.]+)\s+do/, &1))
      |> Enum.map(fn [_match, module] -> module end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp module_ref?(source, module) do
    Regex.match?(~r/(?<![A-Za-z0-9_.])#{Regex.escape(module)}(?![A-Za-z0-9_.])/, source)
  end
end
