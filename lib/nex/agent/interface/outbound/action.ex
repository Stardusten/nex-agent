defmodule Nex.Agent.Interface.Outbound.Action do
  @moduledoc """
  Canonical outbound action event payloads.

  Action events are user-visible control lane items, separate from assistant text
  deltas and tool stdout. Channel adapters may render them with native controls;
  otherwise callers can fall back to the payload content.
  """

  alias Nex.Agent.Interface.Outbound.Approval, as: OutboundApproval
  alias Nex.Agent.Sandbox.Approval.Request

  @metadata_key "_nex_action"
  @action_id_key "_action_id"

  @type status :: :waiting_approval | :allowed | :denied | :running | :done | :failed

  @spec command_payload(Request.t(), status(), keyword()) :: map()
  def command_payload(%Request{} = request, status, opts \\ []) do
    action = command_action(request, status, opts)

    %{
      chat_id: request.chat_id,
      content: render_fallback(action),
      metadata: metadata(action)
    }
  end

  @spec approval_payload(Request.t(), String.t()) :: map()
  def approval_payload(%Request{} = request, fallback_content) do
    action =
      command_action(request, :waiting_approval,
        description: request.description,
        approval?: true
      )

    request
    |> OutboundApproval.payload(fallback_content)
    |> put_in([:metadata, @metadata_key], action)
    |> put_in([:metadata, @action_id_key], action["id"])
  end

  @spec metadata(map()) :: map()
  def metadata(%{} = action) do
    action = stringify_keys(action)

    %{
      @metadata_key => action,
      @action_id_key => Map.get(action, "id")
    }
  end

  @spec action(map() | nil) :: map() | nil
  def action(metadata) when is_map(metadata) do
    case Map.get(metadata, @metadata_key) || Map.get(metadata, :_nex_action) do
      %{} = action -> stringify_keys(action)
      _ -> nil
    end
  end

  def action(_metadata), do: nil

  @spec fallback_content(map()) :: String.t()
  def fallback_content(%{content: content}) when is_binary(content), do: content
  def fallback_content(%{"content" => content}) when is_binary(content), do: content

  def fallback_content(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> action()
    |> render_fallback()
  end

  def fallback_content(%{"metadata" => metadata}) when is_map(metadata) do
    metadata
    |> action()
    |> render_fallback()
  end

  def fallback_content(_payload), do: ""

  @spec render_fallback(map() | nil) :: String.t()
  def render_fallback(%{} = action) do
    base =
      case {Map.get(action, "kind"), Map.get(action, "label"), Map.get(action, "subject")} do
        {"command", label, subject} when is_binary(label) and is_binary(subject) ->
          "#{icon_for(label)} #{label} - #{clean_subject(subject)}"

        {_kind, label, subject} when is_binary(label) and is_binary(subject) ->
          "#{label} - #{clean_subject(subject)}"

        _ ->
          Map.get(action, "description") || "Action"
      end

    case status_label(Map.get(action, "status")) do
      "" -> base
      label -> "#{base} _(#{label})_"
    end
  end

  def render_fallback(_action), do: ""

  @spec status_label(status() | String.t() | atom() | nil) :: String.t()
  def status_label(:waiting_approval), do: "Waiting approval"
  def status_label("waiting_approval"), do: "Waiting approval"
  def status_label(:allowed), do: "Allowed"
  def status_label("allowed"), do: "Allowed"
  def status_label(:denied), do: "Declined"
  def status_label("denied"), do: "Declined"
  def status_label(:running), do: "Running"
  def status_label("running"), do: "Running"
  def status_label(:done), do: "Done"
  def status_label("done"), do: "Done"
  def status_label(:failed), do: "Failed"
  def status_label("failed"), do: "Failed"
  def status_label(_status), do: ""

  defp command_action(%Request{} = request, status, opts) do
    label = Keyword.get(opts, :label, "Bash")
    action_id = Keyword.get(opts, :id) || request.id

    %{
      "id" => action_id,
      "kind" => Atom.to_string(request.kind),
      "operation" => Atom.to_string(request.operation),
      "label" => label,
      "subject" => request.subject,
      "description" => Keyword.get(opts, :description, request.description),
      "status" => status_to_string(status),
      "approval" => Keyword.get(opts, :approval?, false)
    }
  end

  defp status_to_string(status) when is_atom(status), do: Atom.to_string(status)
  defp status_to_string(status) when is_binary(status), do: status
  defp status_to_string(_status), do: "running"

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp clean_subject(subject) do
    subject
    |> to_string()
    |> String.replace("\n", " ")
    |> String.trim()
    |> String.slice(0, 140)
  end

  defp icon_for("Bash"), do: "⚙️"
  defp icon_for(_label), do: "🔐"
end
