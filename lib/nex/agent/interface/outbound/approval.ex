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
        "recommended_rule" => recommended_rule_metadata(request),
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
    maybe_once_action(request) ++
      rule_actions(request) ++
      [
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
  def choice_for_action("approve_rule_session"), do: {:approve, :session}
  def choice_for_action("approve_rule_similar"), do: {:approve, :similar}
  def choice_for_action("approve_session"), do: {:approve, :session}
  def choice_for_action("approve_similar"), do: {:approve, :similar}
  def choice_for_action("approve_always"), do: {:approve, :always}
  def choice_for_action("deny_once"), do: {:deny, :once}
  def choice_for_action(_action_id), do: :error

  @spec status_label(atom(), atom()) :: String.t()
  def status_label(:approved, :once), do: "Allowed"
  def status_label(:approved, :all), do: "Allowed"
  def status_label(:approved, :session), do: "Allowed rule"
  def status_label(:approved, :similar), do: "Allowed rule"
  def status_label(:approved, :always), do: "Allowed rule"
  def status_label(:approved, :grant), do: "Allowed by rule"
  def status_label(:approved, _choice), do: "Allowed"
  def status_label(:denied, _choice), do: "Declined"
  def status_label(:timeout, _choice), do: "Timed out"
  def status_label(:cancelled, _choice), do: "Cancelled"
  def status_label(_status, _choice), do: "Resolved"

  @spec command_for_action(String.t()) :: {:ok, String.t()} | :error
  def command_for_action("approve_once"), do: {:ok, "/approve"}
  def command_for_action("approve_rule_session"), do: {:ok, "/approve session"}
  def command_for_action("approve_rule_similar"), do: {:ok, "/approve similar"}
  def command_for_action("approve_session"), do: {:ok, "/approve session"}
  def command_for_action("approve_similar"), do: {:ok, "/approve similar"}
  def command_for_action("approve_always"), do: {:ok, "/approve always"}
  def command_for_action("deny_once"), do: {:ok, "/deny"}
  def command_for_action(_action_id), do: :error

  @spec recommended_rule_summary(Request.t() | map() | nil) :: String.t() | nil
  def recommended_rule_summary(%Request{} = request) do
    case recommended_rule_option(request) do
      nil ->
        nil

      option ->
        option
        |> rule_subject()
        |> case do
          nil -> nil
          subject -> "Rule: #{subject}."
        end
    end
  end

  def recommended_rule_summary(%{} = metadata) do
    case request(metadata) || stringify_keys(metadata) do
      %{"recommended_rule" => %{"summary" => summary}}
      when is_binary(summary) and summary != "" ->
        summary

      _ ->
        nil
    end
  end

  def recommended_rule_summary(_request), do: nil

  defp action_id_for_custom_id(custom_id) when is_binary(custom_id) do
    case custom_id_parts(custom_id) do
      {:ok, %{action_id: action_id}} -> {:ok, action_id}
      :error -> :error
    end
  end

  defp maybe_once_action(%Request{} = request) do
    if rule_approval_required?(request) do
      []
    else
      [action("approve_once", "Allow once", "/approve #{request.id}", "success")]
    end
  end

  defp rule_approval_required?(%Request{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "requires_rule_approval") == true or
      Map.get(metadata, :requires_rule_approval) == true
  end

  defp rule_approval_required?(_request), do: false

  defp recommended_rule_metadata(%Request{} = request) do
    with %{} = option <- recommended_rule_option(request),
         summary when is_binary(summary) <- recommended_rule_summary(request) do
      choice = rule_choice(option)

      %{
        "summary" => summary,
        "choice" => Atom.to_string(choice),
        "command" => "/approve #{request.id} #{choice}",
        "grant_key" => option["grant_key"] || option[:grant_key],
        "scope" => option["scope"] || option[:scope],
        "proposal_id" => option["proposal_id"] || option[:proposal_id]
      }
    else
      _ -> nil
    end
  end

  defp rule_actions(%Request{} = request) do
    case recommended_rule_option(request) do
      nil ->
        []

      option ->
        id =
          case rule_choice(option) do
            :similar -> "approve_rule_similar"
            :always -> "approve_always"
            :session -> "approve_rule_session"
          end

        [action(id, "Allow rule", "/approve #{request.id} #{rule_choice(option)}", "primary")]
    end
  end

  defp similar_option?(option) when is_map(option) do
    grant_key = to_string(option["grant_key"] || option[:grant_key] || "")

    option["level"] == "similar" or option[:level] == "similar" or
      option["scope"] == "similar" or option[:scope] == "similar" or
      String.contains?(grant_key, ":family:")
  end

  defp similar_option?(_option), do: false

  defp recommended_rule_option(%Request{} = request) do
    Enum.find(request.grant_options, &similar_option?/1) ||
      Enum.find(request.grant_options, &exact_rule_option?/1)
  end

  defp exact_rule_option?(option) when is_map(option) do
    (option["level"] || option[:level]) == "exact" and
      is_map(option["rule"] || option[:rule])
  end

  defp exact_rule_option?(_option), do: false

  defp rule_choice(option) do
    cond do
      similar_option?(option) ->
        :similar

      option["approval_choice"] in ["always", :always] or
          option[:approval_choice] in ["always", :always] ->
        :always

      option["scope"] in ["always", :always] or option[:scope] in ["always", :always] ->
        :always

      true ->
        :session
    end
  end

  defp rule_subject(option) when is_map(option) do
    case option["subject"] || option[:subject] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

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
