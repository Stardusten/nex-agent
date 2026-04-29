defmodule Nex.Agent.Self.CodeUpgrade do
  @moduledoc """
  Helper utilities for CODE-layer source discovery and validation.
  """

  alias Nex.Agent.Capability.Tool.CustomTools

  @protected_modules [
    Nex.Agent.Sandbox.Security,
    Nex.Agent.Self.CodeUpgrade,
    Nex.Agent.Self.HotReload,
    Nex.Agent.Capability.Tool.Registry,
    Nex.Agent.Capability.Tool.Core.SelfUpdate,
    Nex.Agent.Self.Update.Planner,
    Nex.Agent.Self.Update.Deployer,
    Nex.Agent.Self.Update.ReleaseStore
  ]

  @spec source_path(atom()) :: String.t()
  def source_path(module) do
    if CustomTools.custom_module?(module) do
      module
      |> CustomTools.name_for_module()
      |> CustomTools.source_path()
    else
      compile_source = compile_source_path(module)

      if is_binary(compile_source) and File.exists?(compile_source) do
        compile_source
      else
        fallback_source_path(module)
      end
    end
  end

  @spec can_upgrade?(atom()) :: boolean()
  def can_upgrade?(module) do
    Code.ensure_loaded?(module) or
      (CustomTools.custom_module?(module) and File.exists?(source_path(module)))
  end

  @spec list_upgradable_modules() :: [atom()]
  def list_upgradable_modules do
    (app_modules() ++ CustomTools.list_modules())
    |> Enum.filter(&can_upgrade?/1)
    |> Enum.uniq()
  end

  @spec get_source(atom()) :: {:ok, String.t()} | {:error, String.t()}
  def get_source(module) do
    path = source_path(module)

    if File.exists?(path) do
      File.read(path)
    else
      {:error, "Source not found at #{path}"}
    end
  end

  @spec detect_primary_module(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def detect_primary_module(content) when is_binary(content) do
    case Regex.run(~r/defmodule\s+([\w.]+)\s+do/, content) do
      [_, module_str] -> {:ok, Module.concat([module_str])}
      _ -> {:error, "Could not detect module name in source file"}
    end
  end

  @spec code_layer_file?(String.t()) :: boolean()
  def code_layer_file?(path) when is_binary(path) do
    expanded = Path.expand(path)
    lib_root = Path.join(repo_root(), "lib/nex/agent") |> Path.expand()

    String.ends_with?(expanded, ".ex") and String.starts_with?(expanded, lib_root <> "/")
  end

  def code_layer_file?(_path), do: false

  @spec protected_module?(atom()) :: boolean()
  def protected_module?(module) when is_atom(module), do: module in @protected_modules
  def protected_module?(_module), do: false

  @spec related_test_path(String.t()) :: {:ok, String.t(), String.t()} | :none
  def related_test_path(source_path) when is_binary(source_path) do
    repo_root = repo_root()
    source_abs = Path.expand(source_path)
    lib_root = Path.join(repo_root, "lib") |> Path.expand()

    if String.starts_with?(source_abs, lib_root <> "/") do
      relative =
        source_abs
        |> Path.relative_to(lib_root)
        |> Path.rootname(".ex")

      test_path = Path.join([repo_root, "test", relative <> "_test.exs"])
      if File.exists?(test_path), do: {:ok, test_path, repo_root}, else: :none
    else
      :none
    end
  end

  def related_test_path(_source_path), do: :none

  @spec repo_root() :: String.t()
  def repo_root do
    :nex_agent
    |> Application.get_env(:repo_root, File.cwd!())
    |> Path.expand()
  end

  defp app_modules do
    case :application.get_key(:nex_agent, :modules) do
      {:ok, modules} -> modules
      _ -> []
    end
  end

  defp compile_source_path(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         info when is_list(info) <- module.module_info(:compile) do
      case Keyword.get(info, :source) do
        path when is_binary(path) -> path
        path when is_list(path) -> List.to_string(path)
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp fallback_source_path(module) do
    beam_path = :code.where_is_file(~c"#{module}.beam") |> to_string()

    if beam_path == "" or String.contains?(beam_path, "non_existing") or
         not File.exists?(beam_path) do
      module_path =
        module
        |> to_string()
        |> String.replace_prefix("Elixir.", "")
        |> Macro.underscore()

      possible_paths = [
        Path.join([File.cwd!(), "lib", module_path <> ".ex"]),
        Path.join([File.cwd!(), "nex_agent", "lib", module_path <> ".ex"]),
        Path.join([File.cwd!(), "..", "nex_agent", "lib", module_path <> ".ex"])
      ]

      Enum.find(possible_paths, &File.exists?/1) || hd(possible_paths)
    else
      beam_path
      |> Path.rootname(".beam")
      |> Path.rootname(".ez")
      |> String.replace("_build/", "lib/")
      |> String.replace("/ebin/", "/lib/")
      |> String.replace_suffix("", ".ex")
    end
  end
end
