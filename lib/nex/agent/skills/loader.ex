defmodule Nex.Agent.Skills.Loader do
  @moduledoc """
  Skills loader - parses SKILL.md files following Claude Code format.

  ## SKILL.md Format

      ---
      name: explain-code
      description: Explains code with visual diagrams
      disable-model-invocation: false
      allowed-tools: Read, Grep
      requires:
        bins: [browser-use, npx]
        env: [BROWSER_USE_API_KEY]
      always: true
      ---

      When explaining code, always include:
      1. Start with an analogy
      2. Draw a diagram
  """

  require Logger

  @doc """
  Load skills from a directory.

  ## Examples

      skills = Nex.Agent.Skills.Loader.load_from_dir("~/.claude/skills")
  """
  @spec load_from_dir(String.t(), keyword()) :: list(map())
  def load_from_dir(dir, opts \\ []) do
    path = Path.expand(dir)
    filter_unavailable = Keyword.get(opts, :filter_unavailable, true)

    if File.exists?(path) do
      path
      |> File.ls!()
      |> Enum.filter(fn name ->
        has_skill_md?(name) || has_skill_dir?(path, name)
      end)
      |> Enum.flat_map(fn name -> load_skill(name, path) end)
      |> then(fn skills ->
        if filter_unavailable do
          Enum.filter(skills, &check_requirements/1)
        else
          skills
        end
      end)
    else
      []
    end
  end

  @doc """
  Load all skills from standard locations:
  - ~/.nex/agent/workspace/skills (global)
  - .nex/skills (project)
  - Built-in skills (nanobot/skills)
  """
  @spec load_all(keyword()) :: list(map())
  def load_all(opts \\ []) do
    global = Path.join(System.get_env("HOME", "~"), ".nex/agent/workspace/skills")
    project = ".nex/skills"

    # Built-in skills from nanobot format
    builtin = builtin_skills_dir()

    filter_unavailable = Keyword.get(opts, :filter_unavailable, true)
    loader_opts = [filter_unavailable: filter_unavailable]

    []
    |> Kernel.++(load_from_dir(builtin, loader_opts))
    |> Kernel.++(load_from_dir(global, loader_opts))
    |> Kernel.++(load_from_dir(project, loader_opts))
    |> Enum.uniq_by(& &1[:name])
  end

  @doc """
  List all skills without filtering (includes unavailable).
  """
  @spec list_all() :: list(map())
  def list_all, do: load_all(filter_unavailable: false)

  @doc """
  Check if skill requirements are met.
  """
  @spec check_requirements(map()) :: boolean()
  def check_requirements(skill) do
    requires = skill[:requires] || %{}

    # Check binary requirements
    bins = requires[:bins] || []
    bins_ok = Enum.all?(bins, &find_executable/1)

    # Check environment variable requirements
    envs = requires[:env] || []
    envs_ok = Enum.all?(envs, &System.get_env/1)

    bins_ok and envs_ok
  end

  @doc """
  Get missing requirements for a skill.
  """
  @spec missing_requirements(map()) :: String.t()
  def missing_requirements(skill) do
    requires = skill[:requires] || %{}

    missing = []

    bins = requires[:bins] || []

    missing =
      (missing ++ Enum.reject(bins, &find_executable/1))
      |> Enum.map(&"CLI: #{&1}")

    envs = requires[:env] || []

    missing =
      (missing ++ Enum.reject(envs, &System.get_env/1))
      |> Enum.map(&"ENV: #{&1}")

    Enum.join(missing, ", ")
  end

  # Private functions

  defp builtin_skills_dir do
    # Try to find built-in skills relative to this file
    # In production: priv/skills or similar
    # For now, return empty path (no builtins by default)
    ""
  end

  defp has_skill_md?(name) do
    String.ends_with?(name, ".md")
  end

  defp has_skill_dir?(base_path, name) do
    File.dir?(Path.join(base_path, name))
  end

  defp load_skill(name, base_path) do
    skill_path = Path.join([base_path, name, "SKILL.md"])

    cond do
      File.dir?(Path.join(base_path, name)) && File.exists?(skill_path) ->
        [parse_skill_file(skill_path, name)]

      File.exists?(skill_path) ->
        [parse_skill_file(skill_path, name)]

      String.ends_with?(name, ".md") ->
        direct_path = Path.join(base_path, name)
        [parse_skill_file(direct_path, Path.basename(name, ".md"))]

      true ->
        []
    end
  end

  defp parse_skill_file(path, _name) do
    content = File.read!(path)

    # Split by --- frontmatter delimiter
    case Regex.run(~r/^---\n(.*?)\n---\n(.*)$/s, content) do
      [_, frontmatter, body] ->
        parse_skill(frontmatter, body, path)

      nil ->
        # No frontmatter, treat entire content as body
        parse_skill("", content, path)
    end
  end

  defp parse_skill(frontmatter, body, path) do
    metadata = parse_frontmatter(frontmatter)

    # Check for skill.json in the same directory
    skill_dir = Path.dirname(path)

    full_metadata =
      if File.exists?(Path.join(skill_dir, "skill.json")) do
        case File.read!(Path.join(skill_dir, "skill.json")) |> Jason.decode() do
          {:ok, json_meta} -> Map.merge(metadata, json_meta)
          _ -> metadata
        end
      else
        metadata
      end

    name =
      full_metadata["name"] ||
        path |> Path.dirname() |> Path.basename() ||
        Path.basename(path, ".md")

    type = full_metadata["type"] || "markdown"

    # Load code based on type
    code =
      case type do
        "elixir" ->
          skill_ex = Path.join(skill_dir, "skill.ex")
          if File.exists?(skill_ex), do: File.read!(skill_ex), else: ""

        "script" ->
          script_file = Path.join(skill_dir, "script.sh")
          if File.exists?(script_file), do: File.read!(script_file), else: ""

        "mcp" ->
          mcp_file = Path.join(skill_dir, "mcp.json")
          if File.exists?(mcp_file), do: File.read!(mcp_file), else: ""

        _ ->
          String.trim(body)
      end

    # Parse requires section (supports both YAML and simple format)
    requires = parse_requires(full_metadata["requires"])

    %{
      name: name,
      description: full_metadata["description"] || extract_first_paragraph(body),
      content: code,
      type: type,
      code: code,
      parameters: full_metadata["parameters"] || %{},
      disable_model_invocation: full_metadata["disable-model-invocation"] == "true",
      allowed_tools: parse_allowed_tools(full_metadata["allowed-tools"]),
      user_invocable: full_metadata["user-invocable"] != "false",
      always: full_metadata["always"] == "true",
      requires: requires,
      context: full_metadata["context"],
      agent: full_metadata["agent"],
      argument_hint: full_metadata["argument-hint"],
      path: path
    }
  end

  defp parse_requires(nil), do: %{}
  defp parse_requires(""), do: %{}

  defp parse_requires(requires) when is_binary(requires) do
    # Simple format: "binary1, binary2" or "ENV_VAR1, ENV_VAR2"
    # Need to detect if it's bins or env - assume bins for backward compat
    bins =
      requires
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.replace(&1, ~r/^env:/, ""))

    %{bins: bins, env: []}
  end

  defp parse_requires(requires) when is_map(requires) do
    %{
      bins: parse_list(requires["bins"]),
      env: parse_list(requires["env"])
    }
  end

  defp parse_requires(_), do: %{}

  defp parse_list(nil), do: []
  defp parse_list(""), do: []
  defp parse_list(list) when is_list(list), do: list
  defp parse_list(str) when is_binary(str), do: String.split(str, ",") |> Enum.map(&String.trim/1)
  defp parse_list(_), do: []

  defp parse_frontmatter("") do
    %{}
  end

  defp parse_frontmatter(content) do
    content
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> {String.trim(key), String.trim(value)}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{})
  end

  defp parse_allowed_tools(nil), do: []
  defp parse_allowed_tools(""), do: []

  defp parse_allowed_tools(string) do
    string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_first_paragraph("") do
    ""
  end

  defp extract_first_paragraph(body) do
    body
    |> String.split("\n\n")
    |> List.first()
    |> case do
      nil ->
        ""

      para ->
        para
        |> String.trim()
        |> String.slice(0..200)
    end
  end

  # Check if executable exists in PATH
  defp find_executable(bin) do
    # On Windows, also check .exe, .cmd, .bat
    case :os.type() do
      {:win32, _} ->
        Enum.any?([bin, "#{bin}.exe", "#{bin}.cmd", "#{bin}.bat"], fn b ->
          System.find_executable(b) != nil
        end)

      _ ->
        System.find_executable(bin) != nil
    end
  end
end
