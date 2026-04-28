defmodule Nex.Agent.Skills.Catalog do
  @moduledoc """
  Model-facing skill catalog with progressive disclosure.

  Runtime internals keep enough metadata to resolve and read skills, while
  prompt projection stays intentionally small: only `id` and trigger-oriented
  `description` are shown to the model.
  """

  alias Nex.Agent.Workspace
  alias Nex.Agent.Skills.Loader

  @catalog_prompt_budget 8_000
  @builtin_source "builtin"
  @workspace_source "workspace"
  @project_source "project"

  @type card :: %{required(String.t()) => any()}
  @type runtime_data :: %{
          cards: [card()],
          catalog_prompt: String.t(),
          diagnostics: [map()],
          hash: String.t()
        }

  @spec runtime_data(keyword()) :: runtime_data()
  def runtime_data(opts \\ []) do
    {cards, diagnostics} = cards_with_diagnostics(opts)
    {catalog_prompt, prompt_diagnostics} = render_prompt(cards)
    diagnostics = diagnostics ++ prompt_diagnostics

    %{
      cards: cards,
      catalog_prompt: catalog_prompt,
      diagnostics: diagnostics,
      hash: hash({cards, catalog_prompt, diagnostics})
    }
  end

  @spec cards(keyword()) :: [card()]
  def cards(opts \\ []) do
    opts
    |> cards_with_diagnostics()
    |> elem(0)
  end

  @spec catalog_prompt(keyword()) :: String.t()
  def catalog_prompt(opts \\ []) do
    opts
    |> cards()
    |> render_prompt()
    |> elem(0)
  end

  @spec resolve(String.t(), keyword()) :: {:ok, card()} | {:error, String.t()}
  def resolve(id, opts \\ [])

  def resolve(id, opts) when is_binary(id) do
    id = String.trim(id)

    if id == "" do
      {:error, "id is required"}
    else
      catalog_cards = Keyword.get(opts, :catalog_cards) || cards(opts)

      case Enum.find(catalog_cards, &(Map.get(&1, "id") == id)) do
        nil -> {:error, "Skill not found: #{id}"}
        card -> {:ok, card}
      end
    end
  end

  def resolve(_id, _opts), do: {:error, "id is required"}

  @spec read(card()) :: {:ok, map()} | {:error, String.t()}
  def read(%{} = card) do
    path = Map.get(card, "path")

    with true <- present?(path) || {:error, "Skill path is unavailable"},
         {:ok, content} <- File.read(path) do
      {:ok,
       %{
         "id" => Map.get(card, "id"),
         "name" => Map.get(card, "name"),
         "source" => Map.get(card, "source"),
         "path" => path,
         "root_path" => Map.get(card, "root_path"),
         "content" => content,
         "resources" => resources(card)
       }}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Failed to read skill: #{reason}"}

      {:error, reason} ->
        {:error, to_string(reason)}

      false ->
        {:error, "Skill path is unavailable"}
    end
  end

  defp cards_with_diagnostics(opts) do
    sources = [
      {:builtin, &builtin_cards/1},
      {:workspace, &workspace_cards/1},
      {:project, &project_cards/1}
    ]

    {cards, diagnostics} =
      Enum.reduce(sources, {[], []}, fn {source, fun}, {cards_acc, diag_acc} ->
        case fun.(opts) do
          {:ok, source_cards} ->
            {cards_acc ++ source_cards, diag_acc}

          {:error, reason} ->
            {cards_acc, diag_acc ++ [diagnostic(source, reason)]}
        end
      end)

    cards =
      cards
      |> Enum.filter(&model_invocable?/1)
      |> Enum.uniq_by(&Map.get(&1, "id"))
      |> Enum.sort_by(&{source_rank(Map.get(&1, "source")), Map.get(&1, "id") || ""})

    {cards, diagnostics}
  end

  defp builtin_cards(opts) do
    skills =
      opts
      |> Keyword.get(:builtin_skills_dir, builtin_skills_dir())
      |> Loader.load_from_dir(filter_unavailable: false)

    {:ok, Enum.map(skills, &skill_card(&1, @builtin_source))}
  end

  defp workspace_cards(opts) do
    workspace_dir = Workspace.skills_dir(opts)

    skills =
      workspace_dir
      |> Loader.load_from_dir(filter_unavailable: Keyword.get(opts, :filter_unavailable, true))

    {:ok, Enum.map(skills, &skill_card(&1, @workspace_source))}
  end

  defp project_cards(opts) do
    project_dir = Loader.project_skills_dir(opts)

    skills =
      project_dir
      |> Loader.load_from_dir(filter_unavailable: Keyword.get(opts, :filter_unavailable, true))

    {:ok, Enum.map(skills, &skill_card(&1, @project_source))}
  end

  defp skill_card(skill, source) do
    name = to_string(Map.get(skill, :name) || Map.get(skill, "name") || "")
    path = Map.get(skill, :path) || Map.get(skill, "path")

    %{
      "id" => "#{source}:#{name}",
      "name" => name,
      "source" => source,
      "description" =>
        normalize_description(Map.get(skill, :description) || Map.get(skill, "description")),
      "path" => path,
      "root_path" => root_path(path),
      "model_invocable" =>
        not truthy?(
          Map.get(skill, :disable_model_invocation) || Map.get(skill, "disable_model_invocation")
        ),
      "draft" => truthy?(Map.get(skill, :draft) || Map.get(skill, "draft"))
    }
  end

  defp render_prompt([]), do: {"", []}

  defp render_prompt(cards) do
    {skill_lines, _used, omitted} =
      Enum.reduce(cards, {[], base_prompt_size(), []}, fn card, {lines, used, omitted} ->
        line = prompt_card(card)
        next_used = used + String.length(line) + 1

        if next_used <= @catalog_prompt_budget or lines == [] do
          {[line | lines], next_used, omitted}
        else
          {lines, used, [Map.get(card, "id") | omitted]}
        end
      end)

    prompt =
      [
        "## Available Skills",
        "These skill cards stay current for this LLM request. When the task matches a description, call `skill_get` with the skill `id` before following the skill.",
        "",
        "<available_skills>",
        Enum.reverse(skill_lines),
        "</available_skills>"
      ]
      |> List.flatten()
      |> Enum.join("\n")

    diagnostics =
      case omitted do
        [] ->
          []

        ids ->
          [
            %{
              source: "skills",
              code: "skill_catalog_truncated",
              message: "Skill catalog prompt exceeded #{@catalog_prompt_budget} characters",
              omitted_ids: Enum.reverse(ids)
            }
          ]
      end

    {prompt, diagnostics}
  end

  defp prompt_card(card) do
    id = escape_prompt(Map.get(card, "id"))
    description = escape_prompt(Map.get(card, "description"))

    """
      <skill id="#{id}">
        <description>#{description}</description>
      </skill>\
    """
  end

  defp base_prompt_size do
    String.length("""
    ## Available Skills
    These skill cards stay current for this LLM request. When the task matches a description, call `skill_get` with the skill `id` before following the skill.

    <available_skills>
    </available_skills>
    """)
  end

  defp resources(%{"root_path" => root_path, "path" => path}) when is_binary(root_path) do
    root = Path.expand(root_path)

    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(Path.expand(&1) == Path.expand(path || "")))
    |> Enum.reject(&hidden_path?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  defp resources(_card), do: []

  defp root_path(nil), do: nil

  defp root_path(path) when is_binary(path) do
    if Path.basename(path) == "SKILL.md" do
      Path.dirname(path)
    end
  end

  defp model_invocable?(%{"draft" => true}), do: false
  defp model_invocable?(%{"model_invocable" => false}), do: false
  defp model_invocable?(_card), do: true

  defp builtin_skills_dir do
    app_priv =
      case :code.priv_dir(:nex_agent) do
        path when is_list(path) -> Path.join(to_string(path), "skills/builtin")
        _ -> nil
      end

    cond do
      is_binary(app_priv) and File.dir?(app_priv) -> app_priv
      true -> Path.expand("priv/skills/builtin")
    end
  end

  defp normalize_description(nil), do: ""

  defp normalize_description(description) do
    description
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp truthy?(value) when value in [true, "true"], do: true
  defp truthy?(_), do: false

  defp hidden_path?(path) do
    path
    |> Path.split()
    |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp source_rank(@builtin_source), do: 0
  defp source_rank(@workspace_source), do: 1
  defp source_rank(@project_source), do: 2
  defp source_rank(_), do: 9

  defp diagnostic(source, reason) do
    %{
      source: "skills/#{source}",
      code: "skill_catalog_source_failed",
      message: inspect(reason)
    }
  end

  defp escape_prompt(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp hash(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
  end
end
