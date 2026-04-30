defmodule Nex.Agent.Interface.Outbound.Approval do
  @moduledoc """
  Canonical outbound approval control payload shared by channel adapters.

  Channel implementations may render this as native interactive UI. Channels
  that do not support native controls can keep rendering the text body.
  """

  alias Nex.Agent.Sandbox.Approval.Request

  @metadata_key "_nex_approval"
  @custom_id_prefix "nex.approval"

  @type action :: %{
          required(String.t()) => String.t()
        }

  @spec payload(Request.t(), String.t()) :: map()
  def payload(%Request{} = request, content) do
    %{
      chat_id: request.chat_id,
      content: content,
      metadata: metadata(request)
    }
  end

  @spec metadata(Request.t()) :: map()
  def metadata(%Request{} = request) do
    %{
      @metadata_key => %{
        "type" => "approval_request",
        "request_id" => request.id,
        "kind" => Atom.to_string(request.kind),
        "operation" => Atom.to_string(request.operation),
        "subject" => request.subject,
        "description" => request.description,
        "request_metadata" => request.metadata,
        "risk_class" => Map.get(request.metadata, "risk_class"),
        "risk_hint" => Map.get(request.metadata, "risk_hint"),
        "actions" => actions(request)
      },
      "_approval_request_id" => request.id
    }
  end

  @spec request(map() | nil) :: map() | nil
  def request(metadata) when is_map(metadata) do
    case Map.get(metadata, @metadata_key) || Map.get(metadata, :_nex_approval) do
      %{"type" => "approval_request"} = request -> request
      %{type: "approval_request"} = request -> stringify_keys(request)
      _ -> nil
    end
  end

  def request(_metadata), do: nil

  @spec approval_request?(map() | nil) :: boolean()
  def approval_request?(metadata), do: is_map(request(metadata))

  @spec actions(Request.t()) :: [action()]
  def actions(%Request{} = request) do
    [
      action("approve_once", "Approve once", "/approve #{request.id}", "success"),
      action("approve_session", "Allow command", "/approve #{request.id} session", "primary")
    ] ++
      similar_actions(request) ++
      [
        action("approve_always", "Always allow", "/approve #{request.id} always", "secondary"),
        action("deny_once", "Decline", "/deny #{request.id}", "danger")
      ]
  end

  @spec custom_id(String.t(), String.t()) :: String.t()
  def custom_id(request_id, action_id) do
    Enum.join([@custom_id_prefix, request_id, action_id], ":")
  end

  @spec command_for_custom_id(String.t()) :: {:ok, String.t()} | :error
  def command_for_custom_id(custom_id) when is_binary(custom_id) do
    with {:ok, action_id} <- action_id_for_custom_id(custom_id) do
      command_for_action(action_id)
    end
  end

  def command_for_custom_id(_custom_id), do: :error

  @spec custom_id_parts(String.t()) ::
          {:ok, %{request_id: String.t(), action_id: String.t()}} | :error
  def custom_id_parts(custom_id) when is_binary(custom_id) do
    case String.split(custom_id, ":", parts: 3) do
      [@custom_id_prefix, request_id, action_id]
      when request_id != "" and action_id != "" ->
        {:ok, %{request_id: request_id, action_id: action_id}}

      _ ->
        :error
    end
  end

  def custom_id_parts(_custom_id), do: :error

  @spec approval_custom_id?(term()) :: boolean()
  def approval_custom_id?(custom_id) when is_binary(custom_id) do
    match?({:ok, _parts}, custom_id_parts(custom_id))
  end

  def approval_custom_id?(_custom_id), do: false

  @spec choice_for_action(String.t()) :: {:approve, atom()} | {:deny, atom()} | :error
  def choice_for_action("approve_once"), do: {:approve, :once}
  def choice_for_action("approve_session"), do: {:approve, :session}
  def choice_for_action("approve_similar"), do: {:approve, :similar}
  def choice_for_action("approve_always"), do: {:approve, :always}
  def choice_for_action("deny_once"), do: {:deny, :once}
  def choice_for_action(_action_id), do: :error

  @spec status_label(atom(), atom()) :: String.t()
  def status_label(:approved, :once), do: "Allowed"
  def status_label(:approved, :all), do: "Allowed"
  def status_label(:approved, :session), do: "Allowed for session"
  def status_label(:approved, :similar), do: "Allowed similar"
  def status_label(:approved, :always), do: "Always allowed"
  def status_label(:approved, :grant), do: "Allowed by grant"
  def status_label(:approved, _choice), do: "Allowed"
  def status_label(:denied, _choice), do: "Declined"
  def status_label(:timeout, _choice), do: "Timed out"
  def status_label(:cancelled, _choice), do: "Cancelled"
  def status_label(_status, _choice), do: "Resolved"

  @spec command_for_action(String.t()) :: {:ok, String.t()} | :error
  def command_for_action("approve_once"), do: {:ok, "/approve"}
  def command_for_action("approve_session"), do: {:ok, "/approve session"}
  def command_for_action("approve_similar"), do: {:ok, "/approve similar"}
  def command_for_action("approve_always"), do: {:ok, "/approve always"}
  def command_for_action("deny_once"), do: {:ok, "/deny"}
  def command_for_action(_action_id), do: :error

  defp action_id_for_custom_id(custom_id) when is_binary(custom_id) do
    case custom_id_parts(custom_id) do
      {:ok, %{action_id: action_id}} -> {:ok, action_id}
      :error -> :error
    end
  end

  defp similar_actions(%Request{} = request) do
    if Enum.any?(request.grant_options, &similar_option?/1) do
      [action("approve_similar", "Allow similar", "/approve #{request.id} similar", "primary")]
    else
      []
    end
  end

  defp similar_option?(option) when is_map(option) do
    grant_key = to_string(option["grant_key"] || option[:grant_key] || "")

    option["level"] == "similar" or option[:level] == "similar" or
      option["scope"] == "similar" or option[:scope] == "similar" or
      String.contains?(grant_key, ":family:")
  end

  defp similar_option?(_option), do: false

  defp action(id, label, command, style) do
    %{
      "id" => id,
      "label" => label,
      "command" => command,
      "style" => style
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
