defmodule Nex.Agent.Capability.Tool.Core.Hook do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.{Capability.Hooks, Runtime, Runtime.Workspace}

  def name, do: "hook"

  def description do
    """
    Manage runtime hooks in workspace/hooks/hooks.json.

    Hooks are unified AOP-style runtime entries. v1 supports prompt.build.before
    hooks with file or text advice that injects system prompt context for matching
    sessions, channels, chats, or workspaces.
    """
  end

  def category, do: :evolution

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["list", "show", "add_file", "add_text", "enable", "disable", "remove", "test"],
            description: "Hook registry operation"
          },
          id: %{type: "string", description: "Hook id"},
          event: %{
            type: "string",
            description: "Join point event. Defaults to prompt.build.before."
          },
          pointcut: %{type: "object", description: "Exact-match pointcut object"},
          session: %{type: "string", description: "Pointcut session key"},
          channel: %{type: "string", description: "Pointcut Nex channel instance id"},
          chat_id: %{type: "string", description: "Pointcut chat id"},
          parent_chat_id: %{type: "string", description: "Pointcut parent chat id"},
          target_workspace: %{type: "string", description: "Pointcut workspace path"},
          path: %{type: "string", description: "File path for add_file"},
          content: %{type: "string", description: "Text content for add_text"},
          title: %{type: "string", description: "Prompt fragment title"},
          priority: %{type: "integer", description: "Lower priority injects earlier"},
          max_chars: %{type: "integer", description: "Per-hook character cap"},
          on_error: %{
            type: "string",
            enum: ["warn", "skip", "block"],
            description: "Error policy for the hook"
          }
        },
        required: ["action"]
      }
    }
  end

  def execute(%{"action" => action} = args, ctx) do
    workspace = Map.get(ctx, :workspace) || Map.get(ctx, "workspace") || Workspace.root()

    case action do
      "list" -> list_hooks(workspace)
      "show" -> show_hook(args, workspace)
      "add_file" -> add_hook(args, ctx, workspace, "file")
      "add_text" -> add_hook(args, ctx, workspace, "text")
      "enable" -> set_enabled(args, ctx, workspace, true)
      "disable" -> set_enabled(args, ctx, workspace, false)
      "remove" -> remove_hook(args, ctx, workspace)
      "test" -> test_hooks(args, ctx, workspace)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "action is required"}

  defp list_hooks(workspace) do
    hooks = Hooks.load(workspace: workspace)

    {:ok,
     %{
       "registry_path" => Hooks.registry_path(workspace: workspace),
       "version" => hooks.version,
       "hooks" => hooks.entries,
       "diagnostics" => hooks.diagnostics,
       "hash" => hooks.hash
     }}
  end

  defp show_hook(args, workspace) do
    with {:ok, id} <- required_arg(args, "id"),
         {:ok, doc} <- Hooks.read_registry_doc(workspace: workspace) do
      case find_hook(doc, id) do
        nil -> {:error, "Hook not found: #{id}"}
        hook -> {:ok, hook}
      end
    end
  end

  defp add_hook(args, ctx, workspace, kind) do
    with {:ok, id} <- required_arg(args, "id"),
         {:ok, advice} <- build_advice(args, kind, id),
         {:ok, doc} <- Hooks.read_registry_doc(workspace: workspace) do
      entry =
        %{
          "id" => id,
          "enabled" => true,
          "event" => string_arg(args, "event") || "prompt.build.before",
          "pointcut" => build_pointcut(args),
          "advice" => advice
        }
        |> put_default_pointcut(args, ctx)

      hooks =
        doc
        |> Map.get("hooks", [])
        |> Enum.reject(&(Map.get(&1, "id") == id))

      updated = Map.put(doc, "hooks", hooks ++ [entry])

      commit_registry_doc(
        updated,
        workspace,
        ctx,
        %{
          "status" => "saved",
          "hook" => entry,
          "registry_path" => Hooks.registry_path(workspace: workspace)
        }
      )
    end
  end

  defp set_enabled(args, ctx, workspace, enabled) do
    with {:ok, id} <- required_arg(args, "id"),
         {:ok, doc} <- Hooks.read_registry_doc(workspace: workspace) do
      update_existing_hook(doc, id, fn hook -> Map.put(hook, "enabled", enabled) end)
      |> case do
        {:ok, updated, hook} ->
          commit_registry_doc(
            updated,
            workspace,
            ctx,
            %{"status" => if(enabled, do: "enabled", else: "disabled"), "hook" => hook}
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp remove_hook(args, ctx, workspace) do
    with {:ok, id} <- required_arg(args, "id"),
         {:ok, doc} <- Hooks.read_registry_doc(workspace: workspace) do
      hooks = Map.get(doc, "hooks", [])
      updated_hooks = Enum.reject(hooks, &(Map.get(&1, "id") == id))

      if length(updated_hooks) == length(hooks) do
        {:error, "Hook not found: #{id}"}
      else
        updated = Map.put(doc, "hooks", updated_hooks)

        commit_registry_doc(updated, workspace, ctx, %{"status" => "removed", "id" => id})
      end
    end
  end

  defp test_hooks(args, ctx, workspace) do
    hooks = Hooks.load(workspace: workspace)
    id = string_arg(args, "id")

    hooks =
      if id do
        %{hooks | entries: Enum.filter(hooks.entries, &(Map.get(&1, "id") == id))}
      else
        hooks
      end

    test_ctx = %{
      session_key:
        string_arg(args, "session") || Map.get(ctx, :session_key) || Map.get(ctx, "session_key"),
      channel: string_arg(args, "channel") || Map.get(ctx, :channel) || Map.get(ctx, "channel"),
      chat_id: string_arg(args, "chat_id") || Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id"),
      parent_chat_id:
        string_arg(args, "parent_chat_id") ||
          Map.get(ctx, :parent_chat_id) ||
          Map.get(ctx, "parent_chat_id"),
      workspace: string_arg(args, "target_workspace") || workspace,
      run_id: Map.get(ctx, :run_id) || Map.get(ctx, "run_id")
    }

    case Hooks.run(:prompt_build_before, hooks, test_ctx) do
      {:ok, fragments} ->
        {:ok,
         %{
           "matched" => fragments != [],
           "fragment_count" => length(fragments),
           "fragments" => summarize_fragments(fragments)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_advice(args, "file", id) do
    with {:ok, path} <- required_arg(args, "path") do
      {:ok,
       base_advice(args, id)
       |> Map.put("kind", "file")
       |> Map.put("path", path)}
    end
  end

  defp build_advice(args, "text", id) do
    with {:ok, content} <- required_literal_arg(args, "content") do
      {:ok,
       base_advice(args, id)
       |> Map.put("kind", "text")
       |> Map.put("content", content)}
    end
  end

  defp base_advice(args, id) do
    %{
      "title" => string_arg(args, "title") || id,
      "priority" => integer_arg(args, "priority", 100),
      "max_chars" => integer_arg(args, "max_chars", 12_000),
      "on_error" => string_arg(args, "on_error") || "warn"
    }
  end

  defp build_pointcut(args) do
    args_pointcut =
      case Map.get(args, "pointcut") do
        pointcut when is_map(pointcut) -> stringify_keys(pointcut)
        _ -> %{}
      end

    args_pointcut
    |> maybe_put("session", string_arg(args, "session"))
    |> maybe_put("channel", string_arg(args, "channel"))
    |> maybe_put("chat_id", string_arg(args, "chat_id"))
    |> maybe_put("parent_chat_id", string_arg(args, "parent_chat_id"))
    |> maybe_put("workspace", string_arg(args, "target_workspace"))
  end

  defp put_default_pointcut(entry, args, ctx) do
    if has_explicit_pointcut?(args) do
      entry
    else
      case default_parent_pointcut(ctx) do
        pointcut when map_size(pointcut) > 0 -> Map.put(entry, "pointcut", pointcut)
        _ -> entry
      end
    end
  end

  defp has_explicit_pointcut?(args) do
    Map.has_key?(args, "pointcut") or
      Enum.any?(["session", "channel", "chat_id", "parent_chat_id", "target_workspace"], fn key ->
        present?(string_arg(args, key))
      end)
  end

  defp default_parent_pointcut(ctx) do
    parent_chat_id = Map.get(ctx, :parent_chat_id) || Map.get(ctx, "parent_chat_id")
    channel = Map.get(ctx, :channel) || Map.get(ctx, "channel")

    case present_string(parent_chat_id) do
      nil ->
        %{}

      parent_chat_id ->
        %{}
        |> maybe_put("channel", present_string(channel))
        |> maybe_put("parent_chat_id", parent_chat_id)
    end
  end

  defp present?(value), do: not is_nil(present_string(value))

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(nil), do: nil
  defp present_string(value), do: to_string(value)

  defp update_existing_hook(doc, id, fun) do
    hooks = Map.get(doc, "hooks", [])

    if Enum.any?(hooks, &(Map.get(&1, "id") == id)) do
      {updated_hooks, updated_hook} =
        Enum.map_reduce(hooks, nil, fn hook, found ->
          if Map.get(hook, "id") == id do
            updated = fun.(hook)
            {updated, updated}
          else
            {hook, found}
          end
        end)

      {:ok, Map.put(doc, "hooks", updated_hooks), updated_hook}
    else
      {:error, "Hook not found: #{id}"}
    end
  end

  defp find_hook(doc, id) do
    doc
    |> Map.get("hooks", [])
    |> Enum.find(&(Map.get(&1, "id") == id))
  end

  defp commit_registry_doc(doc, workspace, ctx, payload) do
    with :ok <- Hooks.write_registry_doc(doc, workspace: workspace),
         {:ok, reload} <- reload_runtime(workspace, ctx) do
      {:ok, Map.put(payload, "runtime_reload", reload)}
    end
  end

  defp reload_runtime(workspace, ctx) do
    case maybe_reload_runtime(workspace, ctx) do
      %{"status" => "error", "reason" => reason} ->
        {:error, "hook registry saved but runtime reload failed: #{reason}"}

      reload ->
        {:ok, reload}
    end
  end

  defp maybe_reload_runtime(workspace, ctx) do
    reload_fun = runtime_reload_fun(ctx)

    cond do
      is_function(reload_fun, 1) ->
        do_reload_runtime(workspace, reload_fun)

      Process.whereis(Runtime) ->
        do_reload_runtime(workspace, &Runtime.reload/1)

      true ->
        %{"status" => "unavailable"}
    end
  end

  defp do_reload_runtime(workspace, reload_fun) do
    path = Hooks.registry_path(workspace: workspace)

    case reload_fun.(workspace: workspace, changed_paths: [path]) do
      {:ok, snapshot} -> %{"status" => "ok", "version" => Map.get(snapshot, :version)}
      {:error, reason} -> %{"status" => "error", "reason" => inspect(reason)}
      other -> %{"status" => "error", "reason" => "unexpected reload result: #{inspect(other)}"}
    end
  end

  defp runtime_reload_fun(ctx) when is_map(ctx) do
    case Map.get(ctx, :runtime_reload_fun) || Map.get(ctx, "runtime_reload_fun") do
      fun when is_function(fun, 1) -> fun
      _ -> nil
    end
  end

  defp runtime_reload_fun(_ctx), do: nil

  defp summarize_fragments(fragments) do
    Enum.map(fragments, fn fragment ->
      Map.take(fragment, [
        "id",
        "title",
        "kind",
        "source",
        "chars",
        "raw_chars",
        "truncated",
        "hash"
      ])
    end)
  end

  defp required_arg(args, key) do
    case string_arg(args, key) do
      nil -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp required_literal_arg(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp string_arg(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp integer_arg(args, key, default) do
    case Map.get(args, key) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
