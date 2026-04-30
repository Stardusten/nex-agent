defmodule Nex.Agent.Capability.Tool.Core.Reflect do
  @moduledoc """
  Self-reflection tool - lets the agent read its own source code, version history,
  and evolution status.
  """

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.{Self.CodeUpgrade, Self.Evolution}
  alias Nex.Agent.Self.Update.ReleaseStore
  alias Nex.Agent.Sandbox.FileSystem

  def name, do: "reflect"

  def description,
    do: "Inspect CODE-layer source modules, version history, diffs, and evolution cycle status."

  @subagent_actions ~w(source versions introspect list_modules)

  def category, do: :evolution
  def surfaces, do: [:all, :subagent]

  def definition do
    definition(:all)
  end

  def definition(:subagent) do
    definition_for_actions(@subagent_actions)
  end

  def definition(_surface) do
    definition_for_actions([
      "source",
      "versions",
      "introspect",
      "list_modules",
      "evolution_status",
      "trigger_evolution",
      "evolution_history"
    ])
  end

  defp definition_for_actions(actions) do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          module: %{
            type: "string",
            description: "Module name to inspect (e.g. Nex.Agent.Turn.Runner)"
          },
          path: %{
            type: "string",
            description: "Repo CODE-layer file path to inspect (e.g. lib/nex/agent/runner.ex)"
          },
          action: %{
            type: "string",
            enum: actions,
            description:
              "source: view current code, versions: list release history, " <>
                "introspect: show module purpose, API, source path, dependencies, and impact, " <>
                "list_modules: list all CODE-layer modules with deployability metadata, " <>
                "evolution_status: show recent evolution activity, " <>
                "trigger_evolution: manually run an evolution cycle, " <>
                "evolution_history: show evolution audit trail"
          }
        },
        required: ["action"]
      }
    }
  end

  # ── Evolution actions ──

  def execute(%{"action" => "evolution_status"}, ctx) do
    workspace = Map.get(ctx, :workspace)
    events = Evolution.recent_events(workspace: workspace)
    signals = Evolution.recent_signals(workspace: workspace)
    candidates = Evolution.recent_candidates(workspace: workspace)

    events_text =
      if events == [] do
        "No evolution events recorded yet."
      else
        events
        |> Enum.take(10)
        |> Enum.map_join("\n", fn e ->
          "- [#{Map.get(e, "timestamp", "?")}] #{event_tag(e)} #{inspect(event_payload(e))}"
        end)
      end

    signals_text =
      if signals == [] do
        "No recent signal observations."
      else
        "#{length(signals)} recent signal observation(s):\n" <>
          (signals
           |> Enum.take(10)
           |> Enum.map_join("\n", fn s ->
             attrs = Map.get(s, "attrs_summary", %{})
             "- [#{Map.get(attrs, "source", "?")}] #{Map.get(attrs, "signal", "")}"
           end))
      end

    candidates_text =
      if candidates == [] do
        "No recent candidates."
      else
        candidates
        |> Enum.take(10)
        |> Enum.map_join("\n", fn candidate ->
          "- [#{candidate["status"]}] #{candidate["candidate_id"]} #{candidate["kind"]}: #{candidate["summary"]}"
        end)
      end

    {:ok,
     """
     ## Evolution Status

     ### Recent Events
     #{events_text}

     ### Recent Signals
     #{signals_text}

     ### Recent Candidates
     #{candidates_text}
     """}
  end

  def execute(%{"action" => "trigger_evolution"}, ctx) when is_map(ctx) do
    if subagent_ctx?(ctx) do
      {:error, "trigger_evolution is not available in subagent runs"}
    else
      trigger_evolution(ctx)
    end
  end

  def execute(%{"action" => "evolution_history"}, ctx) do
    workspace = Map.get(ctx, :workspace)
    events = Evolution.recent_events(workspace: workspace)

    if events == [] do
      {:ok, "No evolution history yet. Run `trigger_evolution` or wait for automatic cycles."}
    else
      formatted =
        events
        |> Enum.map_join("\n\n", fn e ->
          event = event_tag(e)
          ts = Map.get(e, "timestamp", "?")
          payload = event_payload(e)

          case event do
            "evolution.candidate.proposed" ->
              [
                "**[#{ts}] evolution.candidate.proposed**",
                "Kind: #{Map.get(payload, "kind", "?")}",
                "Summary: #{Map.get(payload, "summary", "?")}"
              ]
              |> maybe_append_line(payload["risk"] && "Risk: #{payload["risk"]}")
              |> Enum.join("\n")

            "evolution.candidate.approved" ->
              [
                "**[#{ts}] evolution.candidate.approved**",
                "Candidate: #{Map.get(payload, "candidate_id", "?")}",
                "Mode: #{Map.get(payload, "mode", "?")}"
              ]
              |> maybe_append_line(
                payload["decision_reason"] && "Reason: #{payload["decision_reason"]}"
              )
              |> Enum.join("\n")

            "evolution.candidate.rejected" ->
              [
                "**[#{ts}] evolution.candidate.rejected**",
                "Candidate: #{Map.get(payload, "candidate_id", "?")}"
              ]
              |> maybe_append_line(
                payload["decision_reason"] && "Reason: #{payload["decision_reason"]}"
              )
              |> Enum.join("\n")

            "evolution.candidate.realization.generated" ->
              [
                "**[#{ts}] evolution.candidate.realization.generated**",
                "Candidate: #{Map.get(payload, "candidate_id", "?")}",
                "Mode: #{Map.get(payload, "mode", "?")}"
              ]
              |> maybe_append_line(
                payload["execution"] && "Execution: #{inspect(payload["execution"])}"
              )
              |> Enum.join("\n")

            "evolution.candidate.apply.completed" ->
              [
                "**[#{ts}] evolution.candidate.apply.completed**",
                "Candidate: #{Map.get(payload, "candidate_id", "?")}",
                "Result: #{Map.get(payload, "result_summary", "?")}"
              ]
              |> Enum.join("\n")

            "evolution.candidate.apply.failed" ->
              [
                "**[#{ts}] evolution.candidate.apply.failed**",
                "Candidate: #{Map.get(payload, "candidate_id", "?")}",
                "Error: #{Map.get(payload, "error_summary", "?")}"
              ]
              |> Enum.join("\n")

            "evolution.cycle.completed" ->
              details =
                [
                  "**[#{ts}] Cycle Completed**",
                  "Evidence: #{Map.get(payload, "evidence_count", 0)}, Patterns: #{Map.get(payload, "pattern_count", 0)}, Candidates: #{Map.get(payload, "candidate_count", 0)}"
                ]
                |> maybe_append_line(payload["trigger"] && "Trigger: #{payload["trigger"]}")
                |> maybe_append_line(payload["profile"] && "Profile: #{payload["profile"]}")

              Enum.join(details, "\n")

            _ ->
              "**[#{ts}] #{event}**\n#{inspect(payload)}"
          end
        end)

      {:ok, "## Evolution History\n\n#{formatted}"}
    end
  end

  # ── Code inspection actions ──

  def execute(%{"action" => "list_modules"}, _ctx) do
    modules =
      CodeUpgrade.list_upgradable_modules()
      |> Enum.reject(&custom_tool_module?/1)

    {:ok,
     %{
       status: :ok,
       modules:
         modules
         |> Enum.map(&module_discovery/1)
         |> Enum.sort_by(& &1.module)
     }}
  end

  def execute(%{"action" => "source"} = args, ctx) do
    with {:ok, source_kind, value} <- validate_source_args(args) do
      source_response(source_kind, value, ctx)
    end
  end

  def execute(%{"action" => "introspect", "module" => module_str}, _ctx) do
    with :ok <- reject_custom_module(module_str) do
      module = String.to_existing_atom("Elixir.#{module_str}")

      if CodeUpgrade.can_upgrade?(module) do
        {:ok, format_introspection(introspect_module(module))}
      else
        {:error, "Module is not loaded or upgradable: #{module_str}"}
      end
    end
  rescue
    ArgumentError -> {:error, "Unknown module: #{module_str}"}
  end

  def execute(%{"action" => "versions"} = args, _ctx) do
    with :ok <- maybe_reject_custom_module(Map.get(args, "module")) do
      history = ReleaseStore.history_view()

      releases =
        case Map.get(args, "module") do
          module_str when is_binary(module_str) ->
            Enum.filter(history.releases, fn release ->
              module_str in modules_for_release(release.id)
            end)

          _ ->
            history.releases
        end

      {:ok, %{history | releases: releases}}
    end
  end

  def execute(%{"action" => "introspect"}, _ctx),
    do: {:error, "introspect requires module parameter"}

  def execute(_args, _ctx),
    do:
      {:error,
       "action is required (source, versions, introspect, list_modules, evolution_status, trigger_evolution, evolution_history)"}

  defp event_tag(event), do: Map.get(event, "tag") || Map.get(event, "event") || "?"

  defp event_payload(event),
    do: Map.get(event, "attrs_summary") || Map.get(event, "payload") || %{}

  defp trigger_evolution(ctx) do
    workspace = Map.get(ctx, :workspace)
    provider = Map.get(ctx, :provider, :anthropic)
    model = Map.get(ctx, :model, "claude-sonnet-4-20250514")
    api_key = Map.get(ctx, :api_key)
    base_url = Map.get(ctx, :base_url)

    case Evolution.run_evolution_cycle(
           workspace: workspace,
           trigger: :manual,
           provider: provider,
           model: model,
           api_key: api_key,
           base_url: base_url
         ) do
      {:ok, result} ->
        {:ok,
         """
         ## Evolution Cycle Completed

         - Soul updates applied: #{result.soul_updates}
         - Memory updates applied: #{result.memory_updates}
         - Skill drafts created: #{result.skill_candidates}
         """}

      {:error, reason} ->
        {:error, "Evolution cycle failed: #{inspect(reason)}"}
    end
  end

  defp introspect_module(module) do
    source_path = CodeUpgrade.source_path(module)
    source = read_source(source_path)
    dependencies = dependencies_from_source(source)
    dependents = dependents_for(module)

    %{
      module: module_name(module),
      source_path: source_path,
      moduledoc: moduledoc_for(module),
      public_api: public_api_for(module),
      dependencies: dependencies,
      dependents: dependents,
      runtime_note:
        "Hot-loaded code affects future calls through this module; existing in-flight conversations may still be using already-prepared state until their next turn."
    }
  end

  defp dependents_for(module) do
    target = module_name(module)

    CodeUpgrade.list_upgradable_modules()
    |> Enum.reject(&(&1 == module))
    |> Enum.reject(&custom_tool_module?/1)
    |> Enum.flat_map(fn candidate ->
      source = candidate |> CodeUpgrade.source_path() |> read_source()

      if target in dependencies_from_source(source) do
        [module_name(candidate)]
      else
        []
      end
    end)
    |> Enum.sort()
  end

  defp dependencies_from_source({:ok, source}) do
    source
    |> Code.string_to_quoted()
    |> case do
      {:ok, ast} ->
        ast
        |> collect_dependency_aliases()
        |> Enum.map(&module_name/1)
        |> Enum.filter(&String.starts_with?(&1, "Nex.Agent."))
        |> Enum.uniq()
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp dependencies_from_source(_), do: []

  defp collect_dependency_aliases(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:alias, _, [aliases_ast]} = node, acc ->
          {node, collect_alias_ast(aliases_ast, acc)}

        {:import, _, [module_ast | _]} = node, acc ->
          {node, collect_module_ast(module_ast, acc)}

        {:use, _, [module_ast | _]} = node, acc ->
          {node, collect_module_ast(module_ast, acc)}

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(modules)
  end

  defp collect_alias_ast({:__aliases__, _, parts}, acc), do: MapSet.put(acc, Module.concat(parts))

  defp collect_alias_ast({{:., _, [{:__aliases__, _, prefix}, :{}]}, _, suffixes}, acc) do
    Enum.reduce(suffixes, acc, fn
      {:__aliases__, _, suffix}, acc -> MapSet.put(acc, Module.concat(prefix ++ suffix))
      _other, acc -> acc
    end)
  end

  defp collect_alias_ast(_ast, acc), do: acc

  defp collect_module_ast({:__aliases__, _, parts}, acc),
    do: MapSet.put(acc, Module.concat(parts))

  defp collect_module_ast(_ast, acc), do: acc

  defp moduledoc_for(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} -> String.trim(doc)
      {:docs_v1, _, _, _, :none, _, _} -> "@moduledoc false"
      {:docs_v1, _, _, _, :hidden, _, _} -> "@moduledoc false"
      _ -> "No moduledoc available."
    end
  end

  defp public_api_for(module) do
    module.__info__(:functions)
    |> Enum.reject(fn {name, _arity} -> name in [:module_info, :__info__] end)
    |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
    |> Enum.sort()
  end

  defp format_introspection(info) do
    """
    ## Module Introspection: #{info.module}

    ### Source Path
    #{info.source_path}

    ### Responsibility
    #{info.moduledoc}

    ### Public API
    #{format_list(info.public_api)}

    ### Dependencies
    #{format_list(info.dependencies)}

    ### Impact: Modules That Depend On This
    #{format_list(info.dependents)}

    ### Runtime Note
    #{info.runtime_note}
    """
  end

  defp format_list([]), do: "- none"
  defp format_list(items), do: Enum.map_join(items, "\n", &"- #{&1}")

  defp read_source(path) do
    if is_binary(path) and File.exists?(path), do: File.read(path), else: {:error, :not_found}
  end

  defp module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp maybe_append_line(lines, nil), do: lines
  defp maybe_append_line(lines, line), do: lines ++ [line]

  defp validate_source_args(args) do
    module_str = Map.get(args, "module")
    path = Map.get(args, "path")

    case {present?(module_str), present?(path)} do
      {true, false} ->
        with :ok <- reject_custom_module(module_str) do
          {:ok, :module, module_str}
        end

      {false, true} ->
        {:ok, :path, path}

      {false, false} ->
        {:error, "source requires exactly one of module or path"}

      {true, true} ->
        {:error, "source accepts exactly one of module or path"}
    end
  end

  defp source_response(:module, module_str, _ctx) do
    module = String.to_existing_atom("Elixir.#{module_str}")

    with {:ok, source} <- CodeUpgrade.get_source(module) do
      {:ok,
       %{
         status: :ok,
         module: module_str,
         path: Path.expand(CodeUpgrade.source_path(module)),
         content: source,
         source_kind: :module
       }}
    end
  rescue
    ArgumentError -> {:error, "Unknown module: #{module_str}"}
  end

  defp source_response(:path, path, ctx) do
    expanded = Path.expand(path, CodeUpgrade.repo_root())

    with {:ok, info} <- FileSystem.authorize(expanded, :read, ctx),
         {:ok, exists?} <- FileSystem.exists?(info),
         :ok <- ensure_source_exists(exists?, info.expanded_path),
         :ok <- ensure_code_layer_source(info.expanded_path),
         {:ok, source} <- FileSystem.read_file(info),
         {:ok, module} <- CodeUpgrade.detect_primary_module(source) do
      {:ok,
       %{
         status: :ok,
         module: module_name(module),
         path: info.expanded_path,
         content: source,
         source_kind: :path
       }}
    end
  end

  defp ensure_source_exists(true, _path), do: :ok
  defp ensure_source_exists(false, path), do: {:error, "Source file does not exist: #{path}"}

  defp ensure_code_layer_source(path) do
    if CodeUpgrade.code_layer_file?(path) do
      :ok
    else
      {:error, "reflect source path must be a repo CODE-layer file under lib/nex/agent: #{path}"}
    end
  end

  defp module_discovery(module) do
    path = CodeUpgrade.source_path(module) |> Path.expand()
    protected = CodeUpgrade.protected_module?(module)

    %{
      module: module_name(module),
      path: path,
      deployable: CodeUpgrade.code_layer_file?(path) and not protected,
      protected: protected
    }
  end

  defp modules_for_release(release_id) do
    case ReleaseStore.load_release(release_id) do
      {:ok, release} -> List.wrap(release["modules"])
      {:error, _reason} -> []
    end
  end

  defp maybe_reject_custom_module(module_str) when is_binary(module_str),
    do: reject_custom_module(module_str)

  defp maybe_reject_custom_module(_module_str), do: :ok

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp reject_custom_module(module_str) do
    if custom_tool_module?(module_str) do
      {:error,
       "reflect is for CODE-layer framework modules. For workspace custom tools, inspect/edit files in workspace/tools."}
    else
      :ok
    end
  end

  defp custom_tool_module?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Nex.Agent.Tool.Custom.")
  end

  defp custom_tool_module?(module_str) when is_binary(module_str) do
    String.starts_with?(module_str, "Nex.Agent.Tool.Custom.")
  end

  defp custom_tool_module?(_), do: false

  defp subagent_ctx?(ctx) do
    Map.get(ctx, :tools_filter) in [:subagent, "subagent"] or
      Map.get(ctx, "tools_filter") in [:subagent, "subagent"]
  end
end
