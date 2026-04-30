defmodule Nex.Agent.ReflectToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Self.Update.ReleaseStore
  alias Nex.Agent.Capability.Tool.Core.Reflect

  @repo_root File.cwd!()

  setup do
    previous_repo_root = Application.get_env(:nex_agent, :repo_root)

    on_exit(fn ->
      if previous_repo_root do
        Application.put_env(:nex_agent, :repo_root, previous_repo_root)
      else
        Application.delete_env(:nex_agent, :repo_root)
      end
    end)

    :ok
  end

  test "reflect source returns a unified structured payload for module-first inspection" do
    assert {:ok,
            %{
              status: :ok,
              module: "Nex.Agent.Turn.Runner",
              path: path,
              content: content,
              source_kind: :module
            }} =
             Reflect.execute(%{"action" => "source", "module" => "Nex.Agent.Turn.Runner"}, %{})

    assert path == Path.join(@repo_root, "lib/nex/agent/turn/runner.ex")
    assert content =~ "defmodule Nex.Agent.Turn.Runner do"
  end

  test "reflect source returns the same shape for path-first inspection" do
    path = Path.join(@repo_root, "lib/nex/agent/turn/runner.ex")

    assert {:ok,
            %{
              status: :ok,
              module: "Nex.Agent.Turn.Runner",
              path: ^path,
              content: content,
              source_kind: :path
            }} = Reflect.execute(%{"action" => "source", "path" => path}, %{})

    assert content =~ "defmodule Nex.Agent.Turn.Runner do"
  end

  test "reflect source enforces exactly one of module or path" do
    assert {:error, "source requires exactly one of module or path"} =
             Reflect.execute(%{"action" => "source"}, %{})

    assert {:error, "source accepts exactly one of module or path"} =
             Reflect.execute(
               %{
                 "action" => "source",
                 "module" => "Nex.Agent.Turn.Runner",
                 "path" => "lib/nex/agent/runner.ex"
               },
               %{}
             )
  end

  test "reflect versions reuses the release visibility contract and supports module filtering" do
    repo_root =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-reflect-versions-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(repo_root)
    Application.put_env(:nex_agent, :repo_root, repo_root)

    on_exit(fn -> File.rm_rf!(repo_root) end)

    assert :ok =
             ReleaseStore.save_release(%{
               "id" => "rel-v1",
               "parent_release_id" => nil,
               "timestamp" => "2026-04-24T09:00:00Z",
               "reason" => "v1",
               "files" => [],
               "modules" => ["Nex.Agent.Sample"],
               "tests" => [],
               "status" => "deployed"
             })

    assert :ok =
             ReleaseStore.save_release(%{
               "id" => "rel-v2",
               "parent_release_id" => "rel-v1",
               "timestamp" => "2026-04-24T10:00:00Z",
               "reason" => "v2",
               "files" => [],
               "modules" => ["Nex.Agent.Other"],
               "tests" => [],
               "status" => "deployed"
             })

    assert {:ok, %{status: :ok, current_effective_release: "rel-v2", releases: releases}} =
             Reflect.execute(%{"action" => "versions", "module" => "Nex.Agent.Sample"}, %{})

    assert [
             %{
               id: "rel-v1",
               effective: false,
               rollback_candidate: true,
               status: "deployed",
               reason: "v1"
             }
           ] = releases
  end
end
