defmodule Nex.Agent.Subagent.Profiles do
  @moduledoc """
  Loads subagent profiles from built-ins, runtime config, and workspace files.
  """

  alias Nex.Agent.{Config, Skills.Frontmatter, Workspace}
  alias Nex.Agent.Subagent.Profile

  @agents_dir "subagents"

  @spec load(Config.t() | nil, keyword()) :: %{String.t() => Profile.t()}
  def load(config, opts \\ []) do
    workspace =
      Keyword.get(opts, :workspace) || configured_workspace(config) || Workspace.root(opts)

    Profile.builtin_profiles()
    |> Map.merge(config_profiles(config))
    |> Map.merge(workspace_profiles(workspace))
  end

  @spec definitions(%{String.t() => Profile.t()}) :: [map()]
  def definitions(profiles) when is_map(profiles) do
    profiles
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn profile ->
      %{
        "name" => profile.name,
        "description" => profile.description,
        "model_role" => to_string(profile.model_role),
        "model_key" => profile.model_key,
        "tools_filter" => to_string(profile.tools_filter),
        "tool_allowlist" => profile.tool_allowlist || [],
        "context_mode" => to_string(profile.context_mode),
        "return_mode" => to_string(profile.return_mode),
        "source" => to_string(profile.source)
      }
    end)
  end

  @spec get(map() | nil, String.t() | nil) :: Profile.t()
  def get(profiles, name) when is_map(profiles) do
    normalized = Profile.normalize_name(name || "general") || "general"
    Map.get(profiles, normalized) || Map.fetch!(Profile.builtin_profiles(), "general")
  end

  def get(_profiles, _name), do: Map.fetch!(Profile.builtin_profiles(), "general")

  defp configured_workspace(%Config{} = config), do: Config.configured_workspace(config)
  defp configured_workspace(_), do: nil

  defp config_profiles(%Config{} = config) do
    config
    |> Config.subagent_profile_config()
    |> Enum.reduce(%{}, fn {name, attrs}, acc ->
      case Profile.from_map(name, attrs, source: :config) do
        {:ok, profile} -> Map.put(acc, profile.name, profile)
        {:error, _reason} -> acc
      end
    end)
  end

  defp config_profiles(_), do: %{}

  defp workspace_profiles(workspace) when is_binary(workspace) do
    dir = Path.join(workspace, @agents_dir)

    if File.dir?(dir) do
      dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.reduce(%{}, fn path, acc ->
        case load_profile_file(path) do
          {:ok, profile} -> Map.put(acc, profile.name, profile)
          {:error, _reason} -> acc
        end
      end)
    else
      %{}
    end
  end

  defp workspace_profiles(_), do: %{}

  defp load_profile_file(path) do
    with {:ok, content} <- File.read(path) do
      {frontmatter, body} = Frontmatter.parse_document(content)
      default_name = Path.basename(path, ".md")

      frontmatter =
        frontmatter
        |> Map.put_new("prompt", String.trim(body))

      Profile.from_map(default_name, frontmatter, prompt: String.trim(body), source: :workspace)
    end
  end
end
