defmodule Nex.Agent.Capability.Tool.Core.AddPermissionRule do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Sandbox.Approval
  alias Nex.Agent.Sandbox.Approval.Request
  alias Nex.Agent.Sandbox.PermissionRule
  alias Nex.Agent.Sandbox.PermissionRule.Rule

  @read_operations ~w(read list search stat stream)
  @write_operations ~w(write mkdir)
  @path_operations @read_operations ++ @write_operations

  def name, do: "permission__add_rule"

  def description,
    do:
      "Ask the user to approve a reusable permission rule for this workspace, channel, or thread."

  def category, do: :base
  def surfaces, do: [:all, :base]

  def definition do
    %{
      name: name(),
      description:
        "Request user approval for a reusable permission rule. Use this after repeated approvals or when a task needs durable access such as reading a directory tree. Path rules do not approve bash command execution; use permission__debug__decision first when unsure which requirements a rule covers. The tool only creates an approval request; it does not add the rule unless the user approves it.",
      parameters: %{
        type: "object",
        properties: %{
          resource: %{
            type: "string",
            enum: ["path", "command"],
            description:
              "Rule resource. Use path for filesystem access, command for bash commands."
          },
          path_under: %{
            type: "string",
            description: "Allow matching operations for this directory and all descendants."
          },
          path: %{
            type: "string",
            description: "Allow matching operations for exactly this file or directory path."
          },
          operations: %{
            type: "array",
            items: %{type: "string", enum: @path_operations ++ ["execute"]},
            description:
              "Operations to allow. Path defaults to read/list/search/stat/stream. Command defaults to execute."
          },
          command: %{
            type: "string",
            description: "Exact command string to allow after rule approval."
          },
          command_prefix: %{
            type: "string",
            description:
              "Command prefix string to allow after rule approval, for example `dokobot get` or `curl`."
          },
          requested_execution: %{
            type: "string",
            enum: ["sandboxed", "elevated"],
            description:
              "Optional execution mode constraint for command rules. Use elevated for unsandboxed command rules."
          },
          scope: %{
            type: "string",
            enum: ["thread", "channel", "workspace"],
            description:
              "Where the rule applies. Defaults to thread when channel and chat id are available."
          },
          persistence: %{
            type: "string",
            enum: ["session", "always"],
            description:
              "Whether approval lasts for the current runtime session or is stored durably. Defaults to always."
          },
          reason: %{
            type: "string",
            description: "Short user-visible reason for requesting this rule."
          }
        },
        required: ["resource", "reason"]
      }
    }
  end

  def execute(%{"resource" => resource, "reason" => reason} = args, ctx)
      when is_binary(reason) and reason != "" do
    with {:ok, rule, subject, kind, operation} <- build_rule(resource, args, ctx),
         {:ok, request} <-
           build_request(rule, subject, kind, operation, reason, persistence(args), ctx),
         {:ok, :approved} <- Approval.request(request, approval_opts(ctx)) do
      {:ok,
       %{
         status: :approved,
         rule: PermissionRule.rule_to_map(rule),
         subject: subject,
         persistence: persistence(args)
       }}
    else
      {:error, :denied} ->
        {:error, "permission rule request was declined"}

      {:error, {:cancelled, reason}} ->
        {:error, "permission rule request was cancelled: #{reason}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "permission rule request failed: #{inspect(reason)}"}
    end
  end

  def execute(_args, _ctx), do: {:error, "resource and reason are required"}

  @doc false
  @spec build_rule(String.t(), map(), map()) ::
          {:ok, Rule.t(), String.t(), atom(), atom()} | {:error, String.t()}
  def build_rule("path", args, ctx) do
    with {:ok, path_predicate, path_label} <- path_predicate(args),
         {:ok, operations} <- path_operations(args),
         {:ok, scope, scope_predicates, scope_label} <- scope_predicates(args, ctx) do
      rule =
        Rule.new(%{
          id: "proposal:add_path_rule",
          level: 0,
          effect: :allow,
          scope: scope,
          predicates:
            [
              {:resource_eq, :path},
              {:operation_in, Enum.map(operations, &String.to_existing_atom/1)},
              path_predicate
            ] ++ scope_predicates,
          reason: args["reason"],
          created_by: actor(ctx),
          source: :owner_grant
        })

      operation_label = Enum.join(operations, "/")
      subject = "Allow #{operation_label} #{path_label} #{scope_label}"
      {:ok, rule, subject, :path, String.to_existing_atom(List.first(operations))}
    end
  end

  def build_rule("command", args, ctx) do
    with {:ok, predicate, command_label} <- command_predicate(args, ctx),
         {:ok, scope, scope_predicates, scope_label} <- scope_predicates(args, ctx) do
      execution_predicates =
        case requested_execution(args) do
          nil -> []
          execution -> [{:eq, :requested_execution, execution}]
        end

      rule =
        Rule.new(%{
          id: "proposal:add_command_rule",
          level: 0,
          effect: :allow,
          scope: scope,
          predicates:
            [
              {:resource_eq, :command},
              {:operation_in, [:execute]},
              predicate
            ] ++ execution_predicates ++ scope_predicates,
          reason: args["reason"],
          created_by: actor(ctx),
          source: :owner_grant
        })

      {:ok, rule, "Allow #{command_label} #{scope_label}", :command, :execute}
    end
  end

  def build_rule(_resource, _args, _ctx), do: {:error, "resource must be path or command"}

  defp build_request(%Rule{} = rule, subject, kind, operation, reason, persistence, ctx) do
    workspace = workspace(ctx)
    session_key = session_key(ctx)
    channel = text_value(ctx, :channel)
    chat_id = text_value(ctx, :chat_id)

    if is_nil(workspace) or is_nil(session_key) do
      {:error, "permission rule requests require workspace and session context"}
    else
      rule_map = PermissionRule.rule_to_map(rule)
      grant_key = PermissionRule.grant_key(rule)

      {:ok,
       Request.new(%{
         workspace: workspace,
         session_key: session_key,
         channel: channel,
         chat_id: chat_id,
         kind: kind,
         operation: operation,
         subject: subject,
         description: "Add permission rule: #{subject}",
         grant_key: grant_key,
         grant_options: [
           %{
             "level" => "exact",
             "scope" => persistence,
             "approval_choice" => persistence,
             "proposal_id" => name(),
             "grant_key" => grant_key,
             "subject" => subject,
             "rule" => rule_map
           }
         ],
         metadata: %{
           "requires_rule_approval" => true,
           "permission_rule_request" => true,
           "reason" => reason
         },
         authorized_actor: actor(ctx)
       })}
    end
  end

  defp path_predicate(%{"path_under" => path}) when is_binary(path) and path != "" do
    {:ok, {:path_under, path}, "under #{Path.expand(path)}"}
  end

  defp path_predicate(%{"path" => path}) when is_binary(path) and path != "" do
    {:ok, {:path_eq, path}, "for #{Path.expand(path)}"}
  end

  defp path_predicate(_args), do: {:error, "path rules require path_under or path"}

  defp path_operations(args) do
    operations =
      case Map.get(args, "operations") do
        nil -> @read_operations
        values when is_list(values) -> Enum.map(values, &to_string/1)
        value when is_binary(value) -> [value]
        _ -> []
      end
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    if operations != [] and Enum.all?(operations, &(&1 in @path_operations)) do
      {:ok, operations}
    else
      {:error, "path operations must be one or more of #{Enum.join(@path_operations, ", ")}"}
    end
  end

  defp command_predicate(%{"command" => command}, ctx)
       when is_binary(command) and command != "" do
    tokens = command_tokens(command, ctx)

    if tokens == [],
      do: {:error, "command rule could not tokenize command"},
      else: {:ok, {:exact, :command_tokens, tokens}, "`#{command}`"}
  end

  defp command_predicate(%{"command_prefix" => command}, ctx)
       when is_binary(command) and command != "" do
    tokens = command_tokens(command, ctx)

    if tokens == [],
      do: {:error, "command rule could not tokenize command_prefix"},
      else: {:ok, {:prefix, :command_tokens, tokens}, "`#{command} ...`"}
  end

  defp command_predicate(_args, _ctx),
    do: {:error, "command rules require command or command_prefix"}

  defp command_tokens(command, ctx) do
    %{command_tokens: tokens} =
      PermissionRule.enrich(%{
        tool_name: "bash",
        params: %{"command" => command},
        cwd: text_value(ctx, :cwd) || workspace(ctx),
        workspace: workspace(ctx),
        channel: text_value(ctx, :channel),
        chat_id: text_value(ctx, :chat_id),
        requested_execution: requested_execution(%{}) || :sandboxed
      })

    tokens
  end

  defp scope_predicates(args, ctx) do
    scope = Map.get(args, "scope") || default_scope(ctx)

    case scope do
      "thread" ->
        with {:ok, channel} <- required_context(ctx, :channel, "thread scope requires channel"),
             {:ok, chat_id} <- required_context(ctx, :chat_id, "thread scope requires chat_id") do
          {:ok, :thread, [{:eq, :channel, channel}, {:eq, :chat_id, chat_id}], "in this thread"}
        end

      "channel" ->
        with {:ok, channel} <- required_context(ctx, :channel, "channel scope requires channel") do
          {:ok, :channel, [{:eq, :channel, channel}], "in this channel"}
        end

      "workspace" ->
        {:ok, :workspace, [], "in this workspace"}

      _ ->
        {:error, "scope must be thread, channel, or workspace"}
    end
  end

  defp default_scope(ctx) do
    if text_value(ctx, :channel) && text_value(ctx, :chat_id), do: "thread", else: "workspace"
  end

  defp required_context(ctx, key, error) do
    case text_value(ctx, key) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp requested_execution(args) do
    case Map.get(args, "requested_execution") do
      "elevated" -> :elevated
      "sandboxed" -> :sandboxed
      _ -> nil
    end
  end

  defp persistence(%{"persistence" => "session"}), do: "session"
  defp persistence(%{"persistence" => "always"}), do: "always"
  defp persistence(_args), do: "always"

  defp workspace(ctx) do
    text_value(ctx, :workspace) || text_value(ctx, :cwd)
  end

  defp session_key(ctx) do
    text_value(ctx, :session_key) ||
      case {text_value(ctx, :channel), text_value(ctx, :chat_id)} do
        {channel, chat_id} when is_binary(channel) and is_binary(chat_id) ->
          "#{channel}:#{chat_id}"

        _ ->
          nil
      end
  end

  defp approval_opts(ctx) do
    case Map.get(ctx, :approval_server) || Map.get(ctx, "approval_server") do
      nil -> []
      server -> [server: server]
    end
  end

  defp actor(ctx) do
    %{
      kind: :owner_run,
      channel: text_value(ctx, :channel),
      id: text_value(ctx, :chat_id),
      display: "agent"
    }
  end

  defp text_value(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
