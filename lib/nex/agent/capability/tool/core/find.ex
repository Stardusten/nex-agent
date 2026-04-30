defmodule Nex.Agent.Capability.Tool.Core.Find do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Self.CodeUpgrade
  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Sandbox.{Command, Exec, FileSystem, Policy}

  @default_limit 20
  @max_limit 200

  def name, do: "find"

  def description,
    do: "Search repository text and return structured path, line, column, and preview matches."

  def category, do: :base
  def surfaces, do: [:all, :base, :follow_up, :subagent]

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Text or regex query to search for"},
          path: %{type: "string", description: "Optional file or directory scope"},
          glob: %{type: "string", description: "Optional glob filter, for example *.ex"},
          limit: %{
            type: "integer",
            minimum: 1,
            description: "Maximum number of matches to return"
          }
        },
        required: ["query"]
      }
    }
  end

  def execute(%{"query" => query} = args, ctx) when is_binary(query) and query != "" do
    with {:ok, scope_info} <- scope_path(args, ctx),
         {:ok, matches} <-
           run_search(query, scope_info.expanded_path, Map.get(args, "glob"), ctx) do
      limit = min(normalize_limit(Map.get(args, "limit")), @max_limit)

      {:ok,
       %{
         status: :ok,
         query: query,
         matches: Enum.take(matches, limit),
         truncated: length(matches) > limit
       }}
    end
  end

  def execute(_args, _ctx), do: {:error, "query is required"}

  defp scope_path(%{"path" => path}, ctx) when is_binary(path) and path != "" do
    FileSystem.authorize(path, :search, ctx)
  end

  defp scope_path(_args, ctx) do
    FileSystem.authorize(CodeUpgrade.repo_root(), :search, ctx)
  end

  defp run_search(query, scope_path, glob, ctx) do
    executable = System.find_executable("rg")

    if is_nil(executable) do
      {:error, "ripgrep (rg) is required for find"}
    else
      args =
        ["--json", "--line-number", "--column"]
        |> maybe_add_glob(glob)
        |> Kernel.++([query, scope_path])

      command = %Command{
        program: executable,
        args: args,
        cwd: scope_path,
        timeout_ms: 30_000,
        cancel_ref: Map.get(ctx, :cancel_ref),
        metadata: %{
          workspace: Map.get(ctx, :workspace) || Map.get(ctx, "workspace") || scope_path,
          observe_context: %{
            workspace: Map.get(ctx, :workspace) || Map.get(ctx, "workspace") || scope_path,
            run_id: Map.get(ctx, :run_id),
            session_key: Map.get(ctx, :session_key) || Map.get(ctx, "session_key"),
            channel: Map.get(ctx, :channel) || Map.get(ctx, "channel"),
            chat_id: Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id"),
            tool_call_id: Map.get(ctx, :tool_call_id)
          },
          observe_attrs: %{"tool" => "find"}
        }
      }

      case Exec.run(command, sandbox_policy(ctx, scope_path)) do
        {:ok, %{stdout: output}} ->
          {:ok, parse_rg_json(output)}

        {:error, %{status: :exit, exit_code: 1, stdout: output}} ->
          {:ok, parse_rg_json(output)}

        {:error, %{status: :exit, exit_code: status, stdout: output}} ->
          {:error, "Search failed with status #{status}: #{String.trim(output)}"}

        {:error, %{error: error}} when is_binary(error) ->
          {:error, "Search failed: #{error}"}

        {:error, reason} ->
          {:error, "Search failed: #{inspect(reason)}"}
      end
    end
  end

  defp sandbox_policy(ctx, cwd) do
    case Map.get(ctx, :runtime_snapshot) do
      %{sandbox: %Policy{} = policy} ->
        policy

      _ ->
        ctx
        |> Map.get(:config)
        |> Config.sandbox_runtime(workspace: Map.get(ctx, :workspace, cwd))
    end
  end

  defp maybe_add_glob(args, glob) when is_binary(glob) and glob != "", do: args ++ ["-g", glob]
  defp maybe_add_glob(args, _glob), do: args

  defp parse_rg_json(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "match", "data" => data}} ->
          [format_match(data)]

        _ ->
          []
      end
    end)
  end

  defp format_match(data) do
    path = get_in(data, ["path", "text"])
    preview = get_in(data, ["lines", "text"]) |> to_string() |> String.trim_trailing("\n")
    column = data |> get_in(["submatches"]) |> List.first() |> submatch_column()

    %{
      path: path,
      line: Map.get(data, "line_number"),
      column: column,
      preview: preview
    }
  end

  defp submatch_column(%{"start" => start}), do: start + 1
  defp submatch_column(_submatch), do: nil

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_limit(_limit), do: @default_limit
end
