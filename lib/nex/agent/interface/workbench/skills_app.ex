defmodule Nex.Agent.Interface.Workbench.SkillsApp do
  @moduledoc false

  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Runtime.Snapshot
  alias Nex.Agent.Capability.Skills
  require Log

  @name_regex ~r/^[a-z][a-z0-9_-]{1,63}$/
  @draft_prefix "[Draft] "
  @draft_status_regex ~r/\A\s*<!--\s*status:\s*draft\b.*?-->\s*/s
  @content_limit 120_000

  @source_types %{
    "builtin" => %{
      "label" => "Builtin",
      "kind" => "code-layer packaged skill",
      "writable" => false,
      "description" => "Shipped with NexAgent as builtin skill plugins."
    },
    "workspace" => %{
      "label" => "Workspace",
      "kind" => "durable workspace skill",
      "writable" => true,
      "description" => "Owned by the active workspace and editable through this view."
    },
    "project" => %{
      "label" => "Project",
      "kind" => "repo-local project skill",
      "writable" => false,
      "description" => "Loaded from the active project skill directory and shown read-only here."
    }
  }

  @spec overview(Snapshot.t(), map()) :: map()
  def overview(%Snapshot{} = snapshot, params \\ %{}) when is_map(params) do
    skills = inventory(snapshot)
    filtered = filter_skills(skills, params)
    limit = limit(params)

    %{
      "skills" => Enum.take(filtered, limit),
      "total" => length(filtered),
      "unfiltered_total" => length(skills),
      "summary" => summary(skills),
      "source_types" => @source_types,
      "filters" => %{
        "source" => normalized_filter(params["source"], "all"),
        "status" => normalized_filter(params["status"], "all"),
        "query" => to_string(params["query"] || ""),
        "limit" => limit
      }
    }
  end

  @spec detail(String.t(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def detail(id, %Snapshot{} = snapshot) when is_binary(id) do
    with {:ok, card} <- find_card(id, snapshot),
         {:ok, payload} <- Skills.read_catalog_skill(card) do
      item = skill_item(card, snapshot.workspace)

      {:ok,
       %{
         "skill" =>
           item
           |> Map.put("content", bounded(payload["content"] || ""))
           |> Map.put(
             "content_truncated",
             String.length(payload["content"] || "") > @content_limit
           )
           |> Map.put("resources", List.wrap(payload["resources"]))
       }}
    end
  end

  @spec save(map(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def save(args, %Snapshot{} = snapshot) when is_map(args) do
    name = args["name"] || args[:name]

    with :ok <- validate_workspace_name(name),
         attrs <- save_attrs(args),
         {:ok, skill} <- Skills.create(attrs, workspace: snapshot.workspace),
         id = "workspace:#{skill_name(skill)}",
         {:ok, payload} <- detail(id, snapshot) do
      _ =
        Log.info(
          "workbench.skill.saved",
          %{"id" => id, "name" => skill_name(skill), "draft" => Map.get(skill, :draft) == true},
          workspace: snapshot.workspace
        )

      {:ok, payload}
    end
  end

  @spec publish(String.t(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def publish(id, %Snapshot{} = snapshot) when is_binary(id) do
    with {:ok, name} <- workspace_name_from_id(id),
         {:ok, _skill} <- Skills.publish_draft(name, workspace: snapshot.workspace),
         {:ok, payload} <- detail("workspace:#{name}", snapshot) do
      _ =
        Log.info(
          "workbench.skill.published",
          %{"id" => "workspace:#{name}", "name" => name},
          workspace: snapshot.workspace
        )

      {:ok, payload}
    end
  end

  @spec delete(String.t(), Snapshot.t()) :: {:ok, map()} | {:error, String.t()}
  def delete(id, %Snapshot{} = snapshot) when is_binary(id) do
    with {:ok, name} <- workspace_name_from_id(id),
         :ok <- Skills.delete(name, workspace: snapshot.workspace) do
      _ =
        Log.info(
          "workbench.skill.deleted",
          %{"id" => "workspace:#{name}", "name" => name},
          workspace: snapshot.workspace
        )

      {:ok,
       %{
         "deleted" => true,
         "id" => "workspace:#{name}",
         "summary" => summary(inventory(snapshot))
       }}
    end
  end

  defp inventory(%Snapshot{} = snapshot) do
    snapshot
    |> skill_cards()
    |> Enum.map(&skill_item(&1, snapshot.workspace))
  end

  defp skill_cards(%Snapshot{workspace: workspace}) do
    Skills.all_catalog(workspace: workspace, filter_unavailable: false)
  end

  defp find_card(id, %Snapshot{} = snapshot) do
    normalized_id = String.trim(id)

    case Enum.find(skill_cards(snapshot), &(Map.get(&1, "id") == normalized_id)) do
      nil -> {:error, "Skill not found: #{normalized_id}"}
      card -> {:ok, card}
    end
  end

  defp skill_item(%{} = card, workspace) do
    status = status(card)
    source = Map.get(card, "source") || ""
    id = Map.get(card, "id") || "#{source}:#{Map.get(card, "name") || ""}"

    %{
      "id" => id,
      "name" => Map.get(card, "name") || "",
      "source" => source,
      "source_label" => get_in(@source_types, [source, "label"]) || source,
      "type" => source,
      "type_kind" => get_in(@source_types, [source, "kind"]) || "skill",
      "description" => Map.get(card, "description") || "",
      "status" => status,
      "model_visible" => model_visible?(card),
      "model_invocable" => Map.get(card, "model_invocable") == true,
      "user_invocable" => Map.get(card, "user_invocable") == true,
      "draft" => Map.get(card, "draft") == true,
      "always" => Map.get(card, "always") == true,
      "available" => Map.get(card, "available") != false,
      "missing_requirements" => Map.get(card, "missing_requirements") || "",
      "requires" => Map.get(card, "requires") || %{"bins" => [], "env" => []},
      "path" => path_label(Map.get(card, "path"), workspace),
      "writable" => source == "workspace",
      "actions" => actions(source, status)
    }
  end

  defp save_attrs(args) do
    draft = truthy?(args["draft"] || args[:draft])
    description = args["description"] || args[:description] || ""
    content = args["content"] || args[:content] || ""

    %{
      "name" => String.trim(to_string(args["name"] || args[:name])),
      "description" => maybe_draft_description(description, draft),
      "content" => maybe_draft_content(content, draft),
      "user_invocable" =>
        truthy?(Map.get(args, "user_invocable", Map.get(args, :user_invocable, true))),
      "disable_model_invocation" =>
        truthy?(
          args["disable_model_invocation"] || args["disable-model-invocation"] ||
            args[:disable_model_invocation]
        ),
      "always" => truthy?(args["always"] || args[:always])
    }
  end

  defp filter_skills(skills, params) do
    source = normalized_filter(params["source"], "all")
    status = normalized_filter(params["status"], "all")
    query = params["query"] |> to_string() |> String.downcase() |> String.trim()

    skills
    |> Enum.filter(fn skill -> source == "all" or skill["source"] == source end)
    |> Enum.filter(fn skill -> status == "all" or skill["status"] == status end)
    |> Enum.filter(fn skill -> query == "" or skill_matches?(skill, query) end)
  end

  defp skill_matches?(skill, query) do
    [skill["id"], skill["name"], skill["description"], skill["path"], skill["status"]]
    |> Enum.any?(fn value ->
      value |> to_string() |> String.downcase() |> String.contains?(query)
    end)
  end

  defp summary(skills) do
    %{
      "total" => length(skills),
      "model_visible" => Enum.count(skills, & &1["model_visible"]),
      "workspace_writable" => Enum.count(skills, &(&1["source"] == "workspace")),
      "by_source" => count_by(skills, "source"),
      "by_status" => count_by(skills, "status")
    }
  end

  defp count_by(skills, key) do
    Enum.reduce(skills, %{}, fn skill, acc ->
      value = skill[key] || "unknown"
      Map.update(acc, value, 1, &(&1 + 1))
    end)
  end

  defp status(%{"draft" => true}), do: "draft"
  defp status(%{"available" => false}), do: "unavailable"
  defp status(%{"model_invocable" => false}), do: "model-hidden"
  defp status(%{"user_invocable" => false}), do: "model-only"
  defp status(_card), do: "active"

  defp model_visible?(%{} = card),
    do:
      Map.get(card, "draft") != true and Map.get(card, "model_invocable") == true and
        Map.get(card, "available") != false

  defp actions("workspace", "draft"), do: ["save", "publish", "delete"]
  defp actions("workspace", _status), do: ["save", "delete"]
  defp actions(_source, _status), do: []

  defp workspace_name_from_id(id) do
    case String.split(String.trim(id), ":", parts: 2) do
      ["workspace", name] ->
        validate_workspace_name(name) |> then(&if(&1 == :ok, do: {:ok, name}, else: &1))

      [_source, _name] ->
        {:error, "Only workspace skills can be changed from Workbench"}

      _ ->
        {:error, "Skill id must include a source prefix"}
    end
  end

  defp validate_workspace_name(name) when is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:error, "Skill name is required"}

      not Regex.match?(@name_regex, name) ->
        {:error, "Skill name must match #{@name_regex.source}"}

      true ->
        :ok
    end
  end

  defp validate_workspace_name(_), do: {:error, "Skill name is required"}

  defp maybe_draft_description(description, false), do: String.trim(to_string(description))

  defp maybe_draft_description(description, true) do
    description = String.trim(to_string(description))

    if String.starts_with?(description, @draft_prefix) do
      description
    else
      @draft_prefix <> description
    end
  end

  defp maybe_draft_content(content, false), do: String.trim_leading(to_string(content))

  defp maybe_draft_content(content, true) do
    content = String.trim_leading(to_string(content))

    if Regex.match?(@draft_status_regex, content) do
      content
    else
      "<!-- status: draft, source: workbench -->\n\n" <> content
    end
  end

  defp path_label(nil, _workspace), do: ""

  defp path_label(path, workspace) when is_binary(path) do
    expanded = Path.expand(path)
    workspace = Path.expand(workspace || "")
    cwd = File.cwd!() |> Path.expand()

    cond do
      workspace != "" and String.starts_with?(expanded, workspace <> "/") ->
        Path.relative_to(expanded, workspace)

      String.starts_with?(expanded, cwd <> "/") ->
        Path.relative_to(expanded, cwd)

      true ->
        Path.basename(expanded)
    end
  end

  defp limit(params) do
    params
    |> Map.get("limit", "200")
    |> to_string()
    |> Integer.parse()
    |> case do
      {value, ""} -> value |> max(1) |> min(500)
      _ -> 200
    end
  end

  defp normalized_filter(nil, default), do: default
  defp normalized_filter("", default), do: default
  defp normalized_filter(value, _default), do: value |> to_string() |> String.trim()

  defp bounded(content) do
    if String.length(content) > @content_limit do
      String.slice(content, 0, @content_limit) <> "\n...[truncated]"
    else
      content
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp skill_name(skill), do: Map.get(skill, :name) || Map.get(skill, "name") || ""
end
