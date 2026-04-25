defmodule Nex.Agent.Evolution.Executor do
  @moduledoc false

  alias Nex.Agent.{Config, Runner}
  alias Nex.Agent.Tool.{ApplyPatch, Find, MemoryWrite, Read, SelfUpdate, SkillCreate, SoulUpdate}

  @spec realize(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def realize(candidate, mode, ctx) when is_map(candidate) and is_binary(mode) do
    execution =
      case candidate["kind"] do
        "memory_candidate" -> memory_execution(candidate)
        "soul_candidate" -> soul_execution(candidate, ctx)
        "skill_candidate" -> skill_execution(candidate)
        "code_hint" -> code_execution(candidate, mode, ctx)
        "reflection_candidate" -> reflection_execution(candidate)
        "record_only" -> record_only_execution(candidate)
        kind -> {:error, "Unsupported candidate kind: #{kind}"}
      end

    case execution do
      {:error, _} = error ->
        error

      execution when is_map(execution) ->
        {:ok,
         %{
           "candidate_id" => candidate["candidate_id"],
           "kind" => candidate["kind"],
           "mode" => mode,
           "summary" => candidate["summary"],
           "execution" => execution
         }}
    end
  end

  @spec apply_realization(map(), map()) :: {:ok, map()} | {:error, term()}
  def apply_realization(%{"mode" => "plan"} = realization, _ctx) do
    {:ok, Map.put(realization, "result", %{"status" => "planned"})}
  end

  def apply_realization(
        %{
          "kind" => "code_hint",
          "execution" => %{
            "tool" => "code_lane",
            "patch" => patch,
            "files" => files,
            "deploy_reason" => deploy_reason
          }
        } = realization,
        ctx
      ) do
    with {:ok, patch_result} <- apply_patch_fun(ctx).(%{"patch" => patch}, ctx),
         {:ok, deploy_result} <-
           self_update_fun(ctx).(
             %{"action" => "deploy", "reason" => deploy_reason, "files" => files},
             ctx
           ),
         :ok <- ensure_deploy_succeeded(deploy_result) do
      {:ok,
       realization
       |> Map.put("patch_result", patch_result)
       |> Map.put("result", deploy_result)}
    end
  end

  def apply_realization(
        %{"execution" => %{"tool" => "memory_write", "args" => args}} = realization,
        ctx
      ) do
    case MemoryWrite.execute(args, ctx) do
      {:ok, result} -> {:ok, Map.put(realization, "result", result)}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_realization(
        %{"execution" => %{"tool" => "soul_update", "args" => args}} = realization,
        ctx
      ) do
    case SoulUpdate.execute(args, ctx) do
      {:ok, result} -> {:ok, Map.put(realization, "result", result)}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_realization(
        %{"execution" => %{"tool" => "skill_create", "args" => args}} = realization,
        ctx
      ) do
    case SkillCreate.execute(args, ctx) do
      {:ok, result} -> {:ok, Map.put(realization, "result", result)}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_realization(%{"execution" => %{"tool" => tool}}, _ctx) do
    {:error, "Execution mode apply is not supported for #{tool}"}
  end

  defp memory_execution(candidate) do
    %{
      "tool" => "memory_write",
      "args" => %{
        "action" => "append",
        "content" => bounded_content(candidate["summary"], candidate["rationale"])
      }
    }
  end

  defp soul_execution(candidate, ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace")

    current =
      case workspace do
        workspace when is_binary(workspace) ->
          Path.join(workspace, "SOUL.md")
          |> File.read()
          |> case do
            {:ok, content} -> content
            _ -> "# Soul\n"
          end

        _ ->
          "# Soul\n"
      end

    addition = "- " <> String.trim(candidate["summary"] || "")

    content =
      if String.contains?(current, addition) do
        current
      else
        current
        |> String.trim_trailing()
        |> Kernel.<>("\n\n## Owner Approved Evolution\n\n")
        |> Kernel.<>(addition <> "\n")
      end

    %{
      "tool" => "soul_update",
      "args" => %{"content" => content}
    }
  end

  defp skill_execution(candidate) do
    skill_name =
      candidate["summary"]
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")
      |> case do
        "" -> "evolution_candidate"
        value -> String.slice(value, 0, 40)
      end

    %{
      "tool" => "skill_create",
      "args" => %{
        "name" => skill_name,
        "description" => bounded_string(candidate["summary"], 160),
        "content" =>
          """
          # #{bounded_string(candidate["summary"], 80)}

          #{bounded_string(candidate["rationale"], 600)}

          Evidence IDs:
          #{Enum.map_join(candidate["evidence_ids"] || [], "\n", &"- #{&1}")}
          """
          |> String.trim()
      }
    }
  end

  defp code_execution(candidate, "plan", _ctx) do
    %{
      "tool" => "code_lane",
      "mode" => "plan",
      "plan" =>
        bounded_string(
          "Inspect relevant modules with find/read, prepare an owner-reviewed patch, and only use self_update for deploy authority: #{candidate["summary"]}",
          600
        )
    }
  end

  defp code_execution(candidate, "apply", ctx) do
    with {:ok, files, snippets} <- code_context(candidate, ctx),
         {:ok, realization} <- generate_code_realization(candidate, files, snippets, ctx) do
      %{
        "tool" => "code_lane",
        "mode" => "apply",
        "files" => realization["files"],
        "patch" => realization["patch"],
        "deploy_reason" => realization["deploy_reason"],
        "summary" => realization["summary"]
      }
    end
  end

  defp reflection_execution(candidate) do
    %{
      "tool" => "reflection_only",
      "note" => bounded_string(candidate["rationale"], 400)
    }
  end

  defp record_only_execution(candidate) do
    %{
      "tool" => "record_only",
      "note" => bounded_string(candidate["summary"], 240)
    }
  end

  defp code_context(candidate, ctx) do
    files =
      extract_paths(candidate)
      |> case do
        [] -> find_candidate_files(candidate, ctx)
        found -> found
      end
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.take(3)

    if files == [] do
      {:error, "No relevant code files found for code_hint candidate"}
    else
      snippets =
        Enum.map(files, fn path ->
          case read_fun(ctx).(%{"path" => path, "start_line" => 1, "line_count" => 200}, ctx) do
            {:ok, %{"content" => content}} ->
              %{"path" => path, "content" => bounded_string(content, 6000)}

            {:ok, %{content: content}} ->
              %{"path" => path, "content" => bounded_string(content, 6000)}

            {:error, reason} ->
              %{"path" => path, "content" => "READ FAILED: #{inspect(reason)}"}
          end
        end)

      {:ok, files, snippets}
    end
  end

  defp generate_code_realization(candidate, files, snippets, ctx) do
    prompt = """
    Generate a bounded code candidate realization.

    Candidate summary:
    #{candidate["summary"]}

    Candidate rationale:
    #{candidate["rationale"]}

    Evidence ids:
    #{Enum.join(candidate["evidence_ids"] || [], ", ")}

    Target files:
    #{Enum.join(files, "\n")}

    Source snippets:
    #{Jason.encode!(snippets, pretty: true)}

    Return a patch in Codex apply_patch format that only edits the target files above.
    """

    messages = [
      %{
        "role" => "system",
        "content" =>
          "You are preparing an owner-approved code candidate realization. Return only a bounded patch proposal and deploy reason."
      },
      %{"role" => "user", "content" => prompt}
    ]

    llm_opts =
      resolve_runtime_llm_opts(ctx) ++
        [
          tools: code_realization_tool(),
          tool_choice: %{type: "tool", name: "code_candidate_realization"}
        ]

    case llm_call_fun(ctx).(messages, llm_opts) do
      {:ok, %{} = result} -> normalize_code_realization(result, files)
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_realization_response, other}}
    end
  end

  defp normalize_code_realization(result, fallback_files) do
    files =
      case Map.get(result, "files") do
        list when is_list(list) and list != [] -> Enum.map(list, &to_string/1)
        _ -> fallback_files
      end

    patch = Map.get(result, "patch") |> to_string()

    cond do
      String.trim(patch) == "" ->
        {:error, "Code realization returned empty patch"}

      true ->
        {:ok,
         %{
           "summary" =>
             bounded_string(Map.get(result, "summary", "Owner-approved code realization"), 240),
           "files" => files,
           "patch" => patch,
           "deploy_reason" =>
             bounded_string(
               Map.get(result, "deploy_reason", "owner-approved evolution candidate"),
               240
             )
         }}
    end
  end

  defp code_realization_tool do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "code_candidate_realization",
          "description" =>
            "Return a bounded patch proposal and deploy reason for the approved code candidate.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "summary" => %{"type" => "string"},
              "files" => %{"type" => "array", "items" => %{"type" => "string"}},
              "patch" => %{"type" => "string"},
              "deploy_reason" => %{"type" => "string"}
            },
            "required" => ["summary", "files", "patch", "deploy_reason"]
          }
        }
      }
    ]
  end

  defp extract_paths(candidate) do
    [candidate["summary"], candidate["rationale"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
    |> Regex.scan(~r/(?:lib|test)\/[A-Za-z0-9_\/\.-]+\.(?:ex|exs)/u)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp find_candidate_files(candidate, ctx) do
    query = candidate["summary"] |> to_string() |> String.trim()

    case find_fun(ctx).(%{"query" => query, "glob" => "*.{ex,exs}", "limit" => 5}, ctx) do
      {:ok, %{matches: matches}} -> Enum.map(matches, &match_path/1)
      {:ok, %{"matches" => matches}} -> Enum.map(matches, &match_path/1)
      _ -> []
    end
  end

  defp match_path(match) when is_map(match), do: Map.get(match, :path) || Map.get(match, "path")

  defp resolve_runtime_llm_opts(ctx) do
    config =
      Config.load(
        case Map.get(ctx, :config_path) || Map.get(ctx, "config_path") do
          nil -> []
          config_path -> [config_path: config_path]
        end
      )

    model_runtime = Config.default_model_runtime(config)

    [
      provider:
        Map.get(ctx, :provider) || Map.get(ctx, "provider") ||
          (model_runtime && model_runtime.provider),
      model:
        Map.get(ctx, :model) || Map.get(ctx, "model") || (model_runtime && model_runtime.model_id),
      api_key:
        Map.get(ctx, :api_key) || Map.get(ctx, "api_key") ||
          (model_runtime && model_runtime.api_key),
      base_url:
        Map.get(ctx, :base_url) || Map.get(ctx, "base_url") ||
          (model_runtime && model_runtime.base_url),
      provider_options:
        Map.get(ctx, :provider_options) || Map.get(ctx, "provider_options") ||
          (model_runtime && model_runtime.provider_options)
    ]
  end

  defp llm_call_fun(ctx) do
    Map.get(ctx, :llm_call_fun) || Map.get(ctx, "llm_call_fun") ||
      (&Runner.call_llm_for_consolidation/2)
  end

  defp find_fun(ctx), do: Map.get(ctx, :find_fun) || Map.get(ctx, "find_fun") || (&Find.execute/2)
  defp read_fun(ctx), do: Map.get(ctx, :read_fun) || Map.get(ctx, "read_fun") || (&Read.execute/2)

  defp apply_patch_fun(ctx) do
    Map.get(ctx, :apply_patch_fun) || Map.get(ctx, "apply_patch_fun") || (&ApplyPatch.execute/2)
  end

  defp self_update_fun(ctx) do
    Map.get(ctx, :self_update_fun) || Map.get(ctx, "self_update_fun") || (&SelfUpdate.execute/2)
  end

  defp ensure_deploy_succeeded(%{status: :deployed}), do: :ok
  defp ensure_deploy_succeeded(%{"status" => "deployed"}), do: :ok

  defp ensure_deploy_succeeded(%{"status" => status}),
    do: {:error, "self_update returned status #{status}"}

  defp ensure_deploy_succeeded(%{status: status}),
    do: {:error, "self_update returned status #{inspect(status)}"}

  defp ensure_deploy_succeeded(other),
    do: {:error, "unexpected self_update result #{inspect(other)}"}

  defp bounded_content(summary, rationale) do
    [summary, rationale]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> bounded_string(1200)
  end

  defp bounded_string(value, limit) do
    value
    |> to_string()
    |> String.trim()
    |> String.slice(0, limit)
  end
end
