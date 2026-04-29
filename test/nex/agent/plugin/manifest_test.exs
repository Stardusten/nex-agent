defmodule Nex.Agent.Extension.Plugin.ManifestTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Extension.Plugin.Manifest

  test "normalizes a valid manifest" do
    assert {:ok, manifest} =
             Manifest.normalize(
               %{
                 "id" => "builtin:tool.web",
                 "title" => "Web Tools",
                 "version" => "0.1.0",
                 "enabled" => true,
                 "source" => "builtin",
                 "description" => "Search and fetch tools.",
                 "contributes" => %{
                   "tools" => [%{"name" => "web_search", "module" => "Nex.Agent.Tool.WebSearch"}]
                 }
               },
               path: "/tmp/nex.plugin.json"
             )

    assert manifest.id == "builtin:tool.web"
    assert manifest.source == :builtin
    assert manifest.enabled
    assert manifest.path == "/tmp/nex.plugin.json"
    assert get_in(manifest.contributes, ["tools", Access.at(0), "name"]) == "web_search"
  end

  test "rejects ids whose prefix does not match source" do
    assert {:error, reason} =
             Manifest.normalize(%{
               "id" => "workspace:tool.web",
               "title" => "Web Tools",
               "source" => "builtin"
             })

    assert reason =~ "id source prefix"
  end

  test "rejects unsupported ids" do
    assert {:error, reason} =
             Manifest.normalize(%{
               "id" => "builtin:Bad Tool",
               "title" => "Bad",
               "source" => "builtin"
             })

    assert reason =~ "id must match"
  end
end
