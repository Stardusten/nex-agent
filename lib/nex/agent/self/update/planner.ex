defmodule Nex.Agent.Self.Update.Planner do
  @moduledoc false

  alias Nex.Agent.Self.CodeUpgrade
  alias Nex.Agent.Sandbox.{Command, Exec, Policy}

  @type plan_entry :: %{
          path: String.t(),
          relative_path: String.t(),
          module: atom(),
          module_name: String.t(),
          test: String.t() | nil
        }

  @spec plan(nil | [String.t()]) :: {:ok, [plan_entry()], [String.t()]} | {:error, String.t()}
  def plan(files \\ nil)

  def plan(nil) do
    with {:ok, pending_files, warnings} <- pending_code_files() do
      build_plan(pending_files, warnings)
    end
  end

  def plan(files) when is_list(files) do
    build_plan(files, [])
  end

  @spec pending_code_files() :: {:ok, [String.t()], [String.t()]} | {:error, String.t()}
  def pending_code_files do
    repo_root = CodeUpgrade.repo_root()

    command = %Command{
      program: "git",
      args: ["status", "--porcelain", "--", "lib/nex/agent"],
      cwd: repo_root,
      timeout_ms: 10_000,
      metadata: %{workspace: repo_root, observe_attrs: %{"source" => "self_update.planner"}}
    }

    case Exec.run(command, internal_exec_policy()) do
      {:ok, %{stdout: output}} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_porcelain_path/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&Path.join(repo_root, &1))
          |> Enum.filter(&CodeUpgrade.code_layer_file?/1)
          |> Enum.uniq()

        {:ok, files, []}

      {:error, %{stdout: output}} ->
        {:error, "Unable to inspect pending CODE files via git status: #{String.trim(output)}"}

      {:error, %{error: error}} when is_binary(error) ->
        {:error, "Unable to inspect pending CODE files via git status: #{error}"}
    end
  rescue
    e ->
      {:error, "Unable to inspect pending CODE files via git status: #{Exception.message(e)}"}
  end

  defp build_plan(files, warnings) do
    entries =
      files
      |> Enum.uniq()
      |> Enum.map(&Path.expand/1)
      |> Enum.map(&build_entry/1)

    case Enum.find(entries, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        plans = Enum.map(entries, fn {:ok, entry} -> entry end)

        if plans == [] do
          {:error, "No deployable CODE-layer files found"}
        else
          {:ok, plans, warnings}
        end
    end
  end

  defp internal_exec_policy do
    %Policy{
      enabled: false,
      backend: :noop,
      mode: :external,
      network: :restricted,
      filesystem: [],
      protected_paths: [],
      protected_names: [],
      env_allowlist: ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"],
      raw: %{}
    }
  end

  defp build_entry(path) do
    cond do
      not File.exists?(path) ->
        {:error, "Deploy target does not exist: #{path}"}

      not CodeUpgrade.code_layer_file?(path) ->
        {:error, "Only repo CODE-layer files under lib/nex/agent can be deployed: #{path}"}

      true ->
        with {:ok, content} <- File.read(path),
             {:ok, module} <- CodeUpgrade.detect_primary_module(content),
             false <- CodeUpgrade.protected_module?(module) do
          {:ok,
           %{
             path: path,
             relative_path: Path.relative_to(path, CodeUpgrade.repo_root()),
             module: module,
             module_name: module_name(module),
             test: related_test(path)
           }}
        else
          true ->
            {:error, "Protected module cannot be deployed via self_update: #{path}"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp related_test(path) do
    case CodeUpgrade.related_test_path(path) do
      {:ok, test_path, _repo_root} -> test_path
      :none -> nil
    end
  end

  defp module_name(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end

  defp parse_porcelain_path(<<_status1, _status2, ?\s, rest::binary>>) do
    case String.trim(rest) do
      "" -> nil
      path -> path
    end
  end

  defp parse_porcelain_path(_line), do: nil
end
