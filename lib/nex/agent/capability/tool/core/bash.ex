defmodule Nex.Agent.Capability.Tool.Core.Bash do
  @moduledoc false

  @behaviour Nex.Agent.Capability.Tool.Behaviour

  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Interface.Outbound.Action, as: OutboundAction
  alias Nex.Agent.Sandbox.Approval.Request
  alias Nex.Agent.Sandbox.{Command, CommandClassifier, Exec, Permission, Policy, Security}

  def name, do: "bash"
  def description, do: "Execute a shell command"
  def category, do: :base
  def surfaces, do: [:all, :base, :subagent, :cron]

  def definition do
    %{
      name: "bash",
      description:
        "Execute a shell command. Commands run sandboxed by default; use sandbox_permissions=require_escalated with justification only when host network, GUI/native bridge access, or filesystem access outside sandbox limits is required.",
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "Command to execute"},
          timeout: %{
            type: "number",
            description: "Timeout in seconds (default: 120)",
            default: 120
          },
          sandbox_permissions: %{
            type: "string",
            enum: ["default", "require_escalated"],
            description:
              "Use require_escalated only when the command must run outside the sandbox, such as needing outbound network, GUI/native host access, or filesystem access unavailable to the sandbox."
          },
          justification: %{
            type: "string",
            description:
              "Required when sandbox_permissions is require_escalated. Explain why sandboxed execution is insufficient."
          }
        },
        required: ["command"]
      }
    }
  end

  def execute(%{"command" => command} = args, ctx) do
    do_execute(command, args, ctx)
  end

  def execute(_args, _ctx), do: {:error, "command is required"}

  defp do_execute(command, args, ctx) do
    cwd = Map.get(ctx, :cwd, File.cwd!())
    policy = sandbox_policy(ctx, cwd)
    escalation = escalation_request(args)

    timeout =
      args
      |> Map.get("timeout", Map.get(ctx, "timeout") || Map.get(ctx, :timeout, 120))
      |> normalize_timeout()

    with :ok <- Security.validate_command(command),
         {:ok, escalation} <- validate_escalation(escalation),
         {:ok, classification, request, approval_status} <-
           authorize_command(command, ctx, policy, escalation),
         :ok <- maybe_emit_allowed_action(ctx, request, approval_status),
         exec_policy = execution_policy(policy, escalation),
         {:ok, result} <-
           Exec.run(
             %Command{
               program: "sh",
               args: ["-c", command],
               cwd: cwd,
               timeout_ms: timeout,
               cancel_ref: Map.get(ctx, :cancel_ref),
               metadata: exec_metadata(ctx, classification, escalation)
             },
             exec_policy
           ) do
      {:ok, format_success_output(result.stdout, approval_status, ctx, escalation)}
    else
      {:error, %Nex.Agent.Sandbox.Result{} = result} ->
        {:error, format_exec_error(result)}

      {:error, reason} when is_binary(reason) ->
        {:error, "Security: #{reason}"}

      {:error, reason} ->
        {:error, "Security: #{inspect(reason)}"}
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

  defp authorize_command(command, ctx, %Policy{} = policy, escalation) do
    classification = CommandClassifier.classify(command)
    request = command_request(command, classification, ctx, escalation)

    cond do
      escalation.requested? and Permission.approved?(request, approval_opts(ctx)) ->
        {:ok, classification, request, :escalated_by_grant}

      escalation.requested? ->
        request_approval_for_escalation(classification, request, ctx)

      policy_allows_without_prompt?(policy) and not classification.requires_approval? ->
        {:ok, classification, request, :policy_allowed}

      Permission.approved?(request, approval_opts(ctx)) ->
        {:ok, classification, request, :grant_allowed}

      not interactive_approval_context?(request) ->
        {:error, "Sandbox approval required for command: #{classification.summary}"}

      true ->
        approval_opts = approval_request_opts(ctx, request)

        case Permission.request(request, approval_opts) do
          {:ok, :approved} -> {:ok, classification, request, :approved_after_request}
          {:error, :denied} -> {:error, "Sandbox approval denied for command"}
          {:error, {:cancelled, reason}} -> {:error, "Sandbox approval cancelled: #{reason}"}
          {:error, reason} -> {:error, "Sandbox approval failed: #{inspect(reason)}"}
        end
    end
  end

  defp request_approval_for_escalation(classification, request, ctx) do
    cond do
      not interactive_approval_context?(request) ->
        {:error, "Sandbox escalation approval required for command: #{classification.summary}"}

      true ->
        case Permission.request(request, approval_request_opts(ctx, request)) do
          {:ok, :approved} -> {:ok, classification, request, :escalated_after_request}
          {:error, :denied} -> {:error, "Sandbox escalation denied for command"}
          {:error, {:cancelled, reason}} -> {:error, "Sandbox escalation cancelled: #{reason}"}
          {:error, reason} -> {:error, "Sandbox escalation failed: #{inspect(reason)}"}
        end
    end
  end

  defp command_request(command, classification, ctx, escalation) do
    family_options =
      if classification.similar_safe? and not escalation.requested? do
        [
          %{
            "level" => "similar",
            "scope" => "similar",
            "grant_key" => classification.family_key,
            "subject" => "#{classification.program} #{classification.risk_class} family"
          }
        ]
      else
        []
      end

    Request.new(%{
      kind: :command,
      operation: :execute,
      subject: command,
      description: command_request_description(classification, escalation),
      grant_key: command_grant_key(classification, escalation),
      grant_options:
        [
          %{
            "level" => "exact",
            "grant_key" => command_grant_key(classification, escalation),
            "subject" => command
          },
          %{
            "level" => "risk",
            "grant_key" => classification.risk_key,
            "subject" => classification.risk_class
          }
        ] ++ family_options,
      workspace: Map.get(ctx, :workspace) || Map.get(ctx, "workspace") || File.cwd!(),
      session_key: session_key_from_ctx(ctx),
      channel: Map.get(ctx, :channel) || Map.get(ctx, "channel"),
      chat_id: Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id"),
      authorized_actor: actor_from_ctx(ctx),
      metadata: command_request_metadata(classification, escalation)
    })
  end

  defp command_request_description(classification, %{
         requested?: true,
         justification: justification
       }) do
    [
      "Allow unsandboxed shell command: #{classification.summary}",
      "Reason: #{justification}"
    ]
    |> Enum.join("\n")
  end

  defp command_request_description(classification, _escalation) do
    "Allow shell command: #{classification.summary}"
  end

  defp command_grant_key(classification, %{requested?: true}) do
    "command:execute:escalated:#{classification.exact_key}"
  end

  defp command_grant_key(classification, _escalation), do: classification.exact_key

  defp command_request_metadata(classification, escalation) do
    %{
      "risk_class" => classification.risk_class,
      "risk_hint" => escalation_risk_hint(classification, escalation),
      "requires_approval" => classification.requires_approval? or escalation.requested?,
      "sandbox_permissions" => escalation.metadata_value,
      "escalation_justification" => escalation.justification
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp escalation_risk_hint(_classification, %{requested?: true}) do
    "This command will run outside the OS sandbox after approval. Approve only if the command and reason are trusted."
  end

  defp escalation_risk_hint(classification, _escalation), do: classification.risk_hint

  defp policy_allows_without_prompt?(%Policy{} = policy) do
    approval_default(policy) == "allow" or
      Map.get(policy.raw || %{}, "auto_allow_sandboxed_bash")
  end

  defp approval_default(%Policy{raw: raw}) when is_map(raw) do
    raw
    |> Map.get("approval", %{})
    |> case do
      %{} = approval -> Map.get(approval, "default", "ask")
      _ -> "ask"
    end
  end

  defp session_key_from_ctx(ctx) do
    case Map.get(ctx, :session_key) || Map.get(ctx, "session_key") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        channel = Map.get(ctx, :channel) || Map.get(ctx, "channel")
        chat_id = Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id")

        if present?(channel) and present?(chat_id), do: "#{channel}:#{chat_id}", else: "default"
    end
  end

  defp actor_from_ctx(ctx) do
    case Map.get(ctx, :user_id) || Map.get(ctx, "user_id") || Map.get(ctx, :actor) do
      nil -> nil
      value -> %{"id" => to_string(value)}
    end
  end

  defp interactive_approval_context?(%Request{} = request) do
    present?(request.channel) and present?(request.chat_id)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp approval_opts(ctx) do
    case Map.get(ctx, :approval_server) || Map.get(ctx, "approval_server") do
      nil -> []
      server -> [server: server]
    end
  end

  defp approval_request_opts(ctx, %Request{}) do
    opts = approval_opts(ctx)

    if native_stream_approval?(ctx) do
      opts
      |> Keyword.put(:publish?, false)
      |> Keyword.put(:on_pending, fn %Request{} = pending_request ->
        emit_native_approval_request(ctx, pending_request)
      end)
    else
      opts
    end
  end

  defp native_stream_approval?(ctx), do: is_function(Map.get(ctx, :stream_sink), 1)

  defp emit_native_approval_request(ctx, %Request{} = request) do
    payload =
      request
      |> OutboundAction.approval_payload(approval_fallback_content(request))
      |> put_in([:metadata, "channel"], request.channel)
      |> put_in([:metadata, "chat_id"], request.chat_id)

    _ = Map.get(ctx, :stream_sink).({:action, payload})
    :ok
  end

  defp approval_fallback_content(%Request{} = request) do
    [
      "Approval required: #{request.description}",
      request_risk_hint(request),
      approval_command_help(request)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp approval_command_help(%Request{} = request) do
    if Request.elevated?(request) do
      "Use `/approve #{request.id}` or `/deny #{request.id}`."
    else
      approval_grant_command_help(request)
    end
  end

  defp approval_grant_command_help(%Request{} = request) do
    approve_commands =
      [
        "`/approve #{request.id}`",
        "`/approve #{request.id} session`"
      ] ++
        maybe_similar_approval_command(request) ++
        ["`/approve #{request.id} always`"]

    "Use #{Enum.join(approve_commands, ", ")}, or `/deny #{request.id}`."
  end

  defp maybe_similar_approval_command(%Request{} = request) do
    if Enum.any?(request.grant_options, &similar_grant_option?/1) do
      ["`/approve #{request.id} similar`"]
    else
      []
    end
  end

  defp similar_grant_option?(option) when is_map(option) do
    option["level"] == "similar" or option["scope"] == "similar" or
      String.contains?(to_string(option["grant_key"] || ""), ":family:")
  end

  defp similar_grant_option?(_option), do: false

  defp request_risk_hint(%Request{metadata: %{"risk_hint" => hint}})
       when is_binary(hint) and hint != "" do
    "Risk: #{hint}"
  end

  defp request_risk_hint(_request), do: nil

  defp exec_metadata(ctx, classification, escalation) do
    %{
      workspace: Map.get(ctx, :workspace) || Map.get(ctx, "workspace") || Map.get(ctx, :cwd),
      observe_context: %{
        workspace: Map.get(ctx, :workspace) || Map.get(ctx, "workspace") || Map.get(ctx, :cwd),
        run_id: Map.get(ctx, :run_id),
        session_key: Map.get(ctx, :session_key) || Map.get(ctx, "session_key"),
        channel: Map.get(ctx, :channel) || Map.get(ctx, "channel"),
        chat_id: Map.get(ctx, :chat_id) || Map.get(ctx, "chat_id"),
        tool_call_id: Map.get(ctx, :tool_call_id)
      },
      observe_attrs:
        %{
          "command_risk_class" => classification.risk_class,
          "command_program" => classification.program,
          "sandbox_permissions" => escalation.metadata_value
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
  end

  defp format_exec_error(%{status: :exit, exit_code: exit_code, stdout: ""}) do
    "Exit code #{exit_code}"
  end

  defp format_exec_error(%{status: :exit, exit_code: exit_code, stdout: output} = result) do
    ["Exit code #{exit_code}", output, sandbox_network_hint(result)]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp format_exec_error(%{status: :timeout}) do
    "Command timed out"
  end

  defp format_exec_error(%{status: :cancelled}) do
    "Command cancelled"
  end

  defp format_exec_error(%{error: error}) when is_binary(error), do: error
  defp format_exec_error(result), do: inspect(result)

  defp sandbox_network_hint(%{sandbox: %{"network" => "restricted"}, stdout: output})
       when is_binary(output) do
    if network_failure_output?(output) do
      "Sandbox note: outbound network is restricted for this command, so DNS or connection failures from curl/npm may be sandbox policy rather than host DNS."
    end
  end

  defp sandbox_network_hint(_result), do: nil

  defp network_failure_output?(output) do
    String.contains?(output, [
      "Could not resolve host",
      "Failed to connect",
      "Network is unreachable",
      "Operation not permitted",
      "nodename nor servname",
      "ENOTFOUND",
      "EAI_AGAIN"
    ])
  end

  defp blank?(value), do: is_nil(value) or value == ""

  defp format_success_output(stdout, approval_status, ctx, escalation) do
    if Map.get(ctx, :tool_result_format) == :envelope do
      %{
        content: stdout,
        metadata: %{
          "sandbox" =>
            %{
              "approval_status" => Atom.to_string(approval_status),
              "llm_note" => approval_llm_note(approval_status),
              "permissions" => escalation.metadata_value
            }
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)
            |> Map.new()
        }
      }
    else
      stdout
    end
  end

  defp approval_llm_note(:approved_after_request) do
    "user approved before execution"
  end

  defp approval_llm_note(:grant_allowed) do
    "allowed by prior approval"
  end

  defp approval_llm_note(:policy_allowed) do
    "allowed by sandbox policy"
  end

  defp approval_llm_note(:escalated_after_request) do
    "user approved unsandboxed execution before the command ran"
  end

  defp approval_llm_note(:escalated_by_grant) do
    "allowed by prior approval for unsandboxed execution"
  end

  defp approval_llm_note(_status), do: nil

  defp escalation_request(args) do
    case Map.get(args, "sandbox_permissions") || Map.get(args, :sandbox_permissions) do
      "require_escalated" ->
        %{
          requested?: true,
          metadata_value: "require_escalated",
          justification:
            normalize_optional_string(
              Map.get(args, "justification") || Map.get(args, :justification)
            )
        }

      :require_escalated ->
        %{
          requested?: true,
          metadata_value: "require_escalated",
          justification:
            normalize_optional_string(
              Map.get(args, "justification") || Map.get(args, :justification)
            )
        }

      _other ->
        %{requested?: false, metadata_value: nil, justification: nil}
    end
  end

  defp validate_escalation(%{requested?: true, justification: nil}) do
    {:error, "justification is required when sandbox_permissions is require_escalated"}
  end

  defp validate_escalation(escalation), do: {:ok, escalation}

  defp execution_policy(%Policy{} = policy, %{requested?: true}) do
    %Policy{
      policy
      | enabled: false,
        backend: :noop,
        mode: :danger_full_access,
        network: :enabled,
        filesystem: []
    }
  end

  defp execution_policy(%Policy{} = policy, _escalation), do: policy

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp maybe_emit_allowed_action(ctx, %Request{} = request, status)
       when status in [:policy_allowed, :grant_allowed, :escalated_by_grant] do
    case Map.get(ctx, :stream_sink) do
      sink when is_function(sink, 1) ->
        payload =
          request
          |> OutboundAction.command_payload(:allowed)
          |> put_in([:metadata, "channel"], request.channel)
          |> put_in([:metadata, "chat_id"], request.chat_id)

        _ = sink.({:action, payload})
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_emit_allowed_action(_ctx, _request, _status), do: :ok

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout * 1000

  defp normalize_timeout(timeout) when is_float(timeout) and timeout > 0,
    do: trunc(timeout * 1000)

  defp normalize_timeout(_), do: 120_000
end
