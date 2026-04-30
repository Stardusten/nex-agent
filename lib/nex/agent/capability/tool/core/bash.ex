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
      description: "Execute a shell command.",
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "Command to execute"},
          timeout: %{
            type: "number",
            description: "Timeout in seconds (default: 120)",
            default: 120
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

    timeout =
      args
      |> Map.get("timeout", Map.get(ctx, "timeout") || Map.get(ctx, :timeout, 120))
      |> normalize_timeout()

    with :ok <- Security.validate_command(command),
         {:ok, classification, request, approval_status} <-
           authorize_command(command, ctx, policy),
         :ok <- maybe_emit_allowed_action(ctx, request, approval_status),
         {:ok, result} <-
           Exec.run(
             %Command{
               program: "sh",
               args: ["-c", command],
               cwd: cwd,
               timeout_ms: timeout,
               cancel_ref: Map.get(ctx, :cancel_ref),
               metadata: exec_metadata(ctx, classification)
             },
             policy
           ) do
      {:ok, format_success_output(result.stdout, approval_status, ctx)}
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

  defp authorize_command(command, ctx, %Policy{} = policy) do
    classification = CommandClassifier.classify(command)
    request = command_request(command, classification, ctx)

    cond do
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

  defp command_request(command, classification, ctx) do
    family_options =
      if classification.similar_safe? do
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
      description: "Allow shell command: #{classification.summary}",
      grant_key: classification.exact_key,
      grant_options:
        [
          %{
            "level" => "exact",
            "grant_key" => classification.exact_key,
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
      metadata: command_request_metadata(classification)
    })
  end

  defp command_request_metadata(classification) do
    %{
      "risk_class" => classification.risk_class,
      "risk_hint" => classification.risk_hint,
      "requires_approval" => classification.requires_approval?
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

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
      "Use `/approve #{request.id}`, `/approve #{request.id} session`, `/approve #{request.id} similar`, `/approve #{request.id} always`, or `/deny #{request.id}`."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp request_risk_hint(%Request{metadata: %{"risk_hint" => hint}})
       when is_binary(hint) and hint != "" do
    "Risk: #{hint}"
  end

  defp request_risk_hint(_request), do: nil

  defp exec_metadata(ctx, classification) do
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
      observe_attrs: %{
        "command_risk_class" => classification.risk_class,
        "command_program" => classification.program
      }
    }
  end

  defp format_exec_error(%{status: :exit, exit_code: exit_code, stdout: ""}) do
    "Exit code #{exit_code}"
  end

  defp format_exec_error(%{status: :exit, exit_code: exit_code, stdout: output}) do
    "Exit code #{exit_code}\n#{output}"
  end

  defp format_exec_error(%{status: :timeout}) do
    "Command timed out"
  end

  defp format_exec_error(%{status: :cancelled}) do
    "Command cancelled"
  end

  defp format_exec_error(%{error: error}) when is_binary(error), do: error
  defp format_exec_error(result), do: inspect(result)

  defp format_success_output(stdout, approval_status, ctx) do
    if Map.get(ctx, :tool_result_format) == :envelope do
      %{
        content: stdout,
        metadata: %{
          "sandbox" => %{
            "approval_status" => Atom.to_string(approval_status),
            "llm_note" => approval_llm_note(approval_status)
          }
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

  defp approval_llm_note(_status), do: nil

  defp maybe_emit_allowed_action(ctx, %Request{} = request, status)
       when status in [:policy_allowed, :grant_allowed] do
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
