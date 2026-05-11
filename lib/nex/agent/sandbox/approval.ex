defmodule Nex.Agent.Sandbox.Approval do
  @moduledoc """
  Deterministic approval state for sandbox and permission requests.

  Session rules are in-memory. Durable rules are persisted under the workspace
  permissions directory. Requests are resolved FIFO per workspace/session.
  """

  use GenServer
  require Logger

  alias Nex.Agent.App.Bus
  alias Nex.Agent.Interface.Outbound
  alias Nex.Agent.Interface.Outbound.Approval, as: OutboundApproval
  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Sandbox.Approval.{Request, Router}
  alias Nex.Agent.Sandbox.{PermissionRule, PermissionRuleStore}
  require Log

  defstruct pending_by_session: %{},
            pending_by_id: %{},
            session_rules: %{},
            always_rules: %{},
            loaded_workspaces: MapSet.new()

  @type approval_result ::
          {:ok, :approved}
          | {:error, :denied}
          | {:error, :timeout}
          | {:error, {:cancelled, :new | :stop | :shutdown | atom()}}
          | {:error, String.t()}

  @type approve_choice :: :once | :all | :session | :similar | :always
  @type deny_choice :: :once | :all

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: name)
  end

  @spec request(Request.t() | map() | keyword(), keyword()) :: approval_result()
  def request(request, opts \\ []) do
    request = normalize_request(request)

    GenServer.call(
      server(opts),
      {:request, request, opts},
      Keyword.get(opts, :timeout, :infinity)
    )
  end

  @spec approve(String.t(), String.t(), approve_choice(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def approve(workspace, session_key, choice \\ :once, opts \\ []) do
    GenServer.call(
      server(opts),
      {:approve, Path.expand(workspace), session_key, choice, opts},
      :infinity
    )
  end

  @spec deny(String.t(), String.t(), deny_choice(), keyword()) :: {:ok, map()} | {:error, term()}
  def deny(workspace, session_key, choice \\ :once, opts \\ []) do
    GenServer.call(
      server(opts),
      {:deny, Path.expand(workspace), session_key, choice, opts},
      :infinity
    )
  end

  @spec approve_request(String.t(), approve_choice(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def approve_request(request_id, choice \\ :once, opts \\ []) do
    GenServer.call(server(opts), {:approve_request, request_id, choice, opts}, :infinity)
  end

  @spec deny_request(String.t(), deny_choice(), keyword()) :: {:ok, map()} | {:error, term()}
  def deny_request(request_id, choice \\ :once, opts \\ []) do
    GenServer.call(server(opts), {:deny_request, request_id, choice, opts}, :infinity)
  end

  @spec pending?(String.t(), String.t(), keyword()) :: boolean()
  def pending?(workspace, session_key, opts \\ []) do
    GenServer.call(server(opts), {:pending?, Path.expand(workspace), session_key})
  end

  @spec pending(String.t(), String.t(), keyword()) :: [Request.t()]
  def pending(workspace, session_key, opts \\ []) do
    GenServer.call(server(opts), {:pending, Path.expand(workspace), session_key})
  end

  @spec pending_workspace(String.t(), keyword()) :: [Request.t()]
  def pending_workspace(workspace, opts \\ []) do
    GenServer.call(server(opts), {:pending_workspace, Path.expand(workspace), opts})
  end

  @spec approved?(String.t(), String.t(), Request.t() | String.t(), keyword()) :: boolean()
  def approved?(workspace, session_key, request_or_grant_key, opts \\ []) do
    GenServer.call(
      server(opts),
      {:approved?, Path.expand(workspace), session_key, request_or_grant_key}
    )
  end

  @spec debug_decision(String.t(), String.t(), PermissionRule.RawToolEvent.t() | map(), keyword()) ::
          PermissionRule.Decision.t()
  def debug_decision(workspace, session_key, raw_event, opts \\ []) do
    GenServer.call(
      server(opts),
      {:debug_decision, Path.expand(workspace), session_key, raw_event, opts}
    )
  end

  @spec list_rules(String.t(), String.t(), keyword()) :: [map()]
  def list_rules(workspace, session_key, opts \\ []) do
    GenServer.call(server(opts), {:list_rules, Path.expand(workspace), session_key})
  end

  @spec revoke_rule(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def revoke_rule(workspace, session_key, rule_ref, opts \\ []) when is_binary(rule_ref) do
    GenServer.call(
      server(opts),
      {:revoke_rule, Path.expand(workspace), session_key, rule_ref},
      :infinity
    )
  end

  @spec cancel_pending(String.t(), String.t(), atom(), keyword()) :: {:ok, map()}
  def cancel_pending(workspace, session_key, reason, opts \\ []) do
    GenServer.call(
      server(opts),
      {:cancel_pending, Path.expand(workspace), session_key, reason},
      :infinity
    )
  end

  @spec reset_session(String.t(), String.t(), atom(), keyword()) :: {:ok, map()}
  def reset_session(workspace, session_key, reason \\ :new, opts \\ []) do
    GenServer.call(
      server(opts),
      {:reset_session, Path.expand(workspace), session_key, reason},
      :infinity
    )
  end

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  @impl true
  def handle_call({:request, %Request{} = request, opts}, from, state) do
    state = ensure_workspace_loaded(state, request.workspace)

    case decision_in_state(state, request.workspace, request.session_key, request) do
      :allow ->
        {:reply, {:ok, :approved}, state}

      :deny ->
        {:reply, {:error, :denied}, state}

      :ask ->
        route = Router.route(request)
        request = put_delivery_route(%{request | from: from}, route)
        state = add_pending(state, request)

        observe_request("sandbox.approval.requested", request, %{
          "status" => "pending",
          "delivery" => route
        })

        notify_pending(request, opts)
        if route == :session and Keyword.get(opts, :publish?, true), do: publish_request(request)
        {:noreply, state}
    end
  end

  def handle_call({:approve, workspace, session_key, :all, opts}, _from, state) do
    state = ensure_workspace_loaded(state, workspace)
    {requests, state} = pop_all_pending(state, workspace, session_key)
    {rule_required, approvable} = Enum.split_with(requests, &rule_approval_required?/1)
    {authorized, unauthorized} = Enum.split_with(approvable, &authorized_resolution?(&1, opts))
    state = Enum.reduce(rule_required ++ unauthorized, state, &add_pending(&2, &1))

    Enum.each(authorized, &resolve_request(&1, :approved, :all, nil))

    {:reply,
     {:ok,
      %{
        approved: length(authorized),
        skipped_rule_required: length(rule_required),
        skipped_unauthorized: length(unauthorized),
        granted: nil,
        choice: :all
      }}, state}
  end

  def handle_call({:approve, workspace, session_key, choice, opts}, _from, state)
      when choice in [:once, :session, :similar, :always] do
    state = ensure_workspace_loaded(state, workspace)

    with {:ok, request} <- peek_pending(state, workspace, session_key),
         :ok <- authorize_resolution(request, opts),
         {:ok, grant_spec} <- grant_spec_for_choice(request, choice),
         {:ok, state, grant} <-
           apply_grant_spec(state, workspace, session_key, request, grant_spec) do
      {_request, state} = pop_pending_by_id(state, workspace, session_key, request.id)

      swept =
        state
        |> sweep_approved_pending(workspace, session_key, grant)
        |> Enum.filter(&authorized_resolution?(&1, opts))

      state = pop_requests(state, swept)

      resolve_request(request, :approved, choice, grant)
      Enum.each(swept, &resolve_request(&1, :approved, :grant, grant))

      {:reply, {:ok, %{approved: 1 + length(swept), granted: grant, choice: choice}}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:approve_request, request_id, choice, opts}, _from, state)
      when choice in [:once, :session, :similar, :always] do
    with {:ok, request} <- pending_by_request_id(state, request_id),
         state <- ensure_workspace_loaded(state, request.workspace),
         :ok <- authorize_resolution(request, opts),
         {:ok, grant_spec} <- grant_spec_for_choice(request, choice),
         {:ok, state, grant} <-
           apply_grant_spec(state, request.workspace, request.session_key, request, grant_spec) do
      {_request, state} =
        pop_pending_by_id(state, request.workspace, request.session_key, request.id)

      swept =
        state
        |> sweep_approved_pending(request.workspace, request.session_key, grant)
        |> Enum.filter(&authorized_resolution?(&1, opts))

      state = pop_requests(state, swept)

      resolve_request(request, :approved, choice, grant)
      Enum.each(swept, &resolve_request(&1, :approved, :grant, grant))

      {:reply,
       {:ok,
        %{
          approved: 1 + length(swept),
          granted: grant,
          choice: choice,
          request_id: request.id,
          swept: Enum.map(swept, & &1.id)
        }}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:approve_request, _request_id, choice, _opts}, _from, state) do
    {:reply, {:error, {:unknown_approval_choice, choice}}, state}
  end

  def handle_call({:approve, _workspace, _session_key, choice, _opts}, _from, state) do
    {:reply, {:error, {:unknown_approval_choice, choice}}, state}
  end

  def handle_call({:deny, workspace, session_key, :all, opts}, _from, state) do
    {requests, state} = pop_all_pending(state, workspace, session_key)
    {authorized, unauthorized} = Enum.split_with(requests, &authorized_resolution?(&1, opts))
    state = Enum.reduce(unauthorized, state, &add_pending(&2, &1))
    Enum.each(authorized, &resolve_request(&1, :denied, :all, nil))

    {:reply,
     {:ok,
      %{denied: length(authorized), skipped_unauthorized: length(unauthorized), choice: :all}},
     state}
  end

  def handle_call({:deny, workspace, session_key, :once, opts}, _from, state) do
    with {:ok, request} <- peek_pending(state, workspace, session_key),
         :ok <- authorize_resolution(request, opts) do
      {_request, state} = pop_pending_by_id(state, workspace, session_key, request.id)

      resolve_request(request, :denied, :once, nil)
      {:reply, {:ok, %{denied: 1, choice: :once}}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:deny_request, request_id, :once, opts}, _from, state) do
    with {:ok, request} <- pending_by_request_id(state, request_id),
         :ok <- authorize_resolution(request, opts) do
      {_request, state} =
        pop_pending_by_id(state, request.workspace, request.session_key, request.id)

      resolve_request(request, :denied, :once, nil)
      {:reply, {:ok, %{denied: 1, choice: :once, request_id: request.id}}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:deny_request, _request_id, choice, _opts}, _from, state) do
    {:reply, {:error, {:unknown_deny_choice, choice}}, state}
  end

  def handle_call({:deny, _workspace, _session_key, choice, _opts}, _from, state) do
    {:reply, {:error, {:unknown_deny_choice, choice}}, state}
  end

  def handle_call({:pending?, workspace, session_key}, _from, state) do
    {:reply, pending_requests(state, workspace, session_key) != [], state}
  end

  def handle_call({:pending, workspace, session_key}, _from, state) do
    {:reply, Enum.map(pending_requests(state, workspace, session_key), &hide_from/1), state}
  end

  def handle_call({:pending_workspace, workspace, opts}, _from, state) do
    route = Keyword.get(opts, :delivery)

    requests =
      state.pending_by_id
      |> Map.values()
      |> Enum.filter(&(Path.expand(&1.workspace) == workspace))
      |> Enum.filter(&matches_delivery?(&1, route))
      |> Enum.sort_by(&DateTime.to_unix(&1.requested_at || DateTime.utc_now(), :microsecond))
      |> Enum.map(&hide_from/1)

    {:reply, requests, state}
  end

  def handle_call({:approved?, workspace, session_key, request_or_grant_key}, _from, state) do
    state = ensure_workspace_loaded(state, workspace)
    {:reply, approved_in_state?(state, workspace, session_key, request_or_grant_key), state}
  end

  def handle_call({:debug_decision, workspace, session_key, raw_event, opts}, _from, state) do
    state = ensure_workspace_loaded(state, workspace)
    extra_rules = Keyword.get(opts, :extra_rules, [])
    rules = session_rules(state, workspace, session_key) ++ always_rules(state, workspace)
    decision = PermissionRule.decide(raw_event, rules ++ extra_rules)
    {:reply, decision, state}
  end

  def handle_call({:list_rules, workspace, session_key}, _from, state) do
    state = ensure_workspace_loaded(state, workspace)
    {:reply, rule_entries(state, workspace, session_key), state}
  end

  def handle_call({:revoke_rule, workspace, session_key, rule_ref}, _from, state) do
    state = ensure_workspace_loaded(state, workspace)

    case revoke_rule_in_state(state, workspace, session_key, rule_ref) do
      {:ok, state, entry} ->
        observe_rule_revoked(workspace, session_key, entry)
        {:reply, {:ok, entry}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel_pending, workspace, session_key, reason}, _from, state) do
    {requests, state} = pop_all_pending(state, workspace, session_key)
    Enum.each(requests, &reply_request(&1, {:error, {:cancelled, reason}}))
    Enum.each(requests, &observe_request("sandbox.approval.cancelled", &1, %{"reason" => reason}))
    {:reply, {:ok, %{cancelled: length(requests), reason: reason}}, state}
  end

  def handle_call({:reset_session, workspace, session_key, reason}, _from, state) do
    {requests, state} = pop_all_pending(state, workspace, session_key)
    Enum.each(requests, &reply_request(&1, {:error, {:cancelled, reason}}))
    Enum.each(requests, &observe_request("sandbox.approval.cancelled", &1, %{"reason" => reason}))

    state = %{
      state
      | session_rules: delete_session_rules(state.session_rules, workspace, session_key)
    }

    {:reply, {:ok, %{cancelled: length(requests), cleared_session_rules: true}}, state}
  end

  defp normalize_request(%Request{} = request),
    do: %{request | workspace: Path.expand(request.workspace)}

  defp normalize_request(attrs), do: Request.new(attrs)

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

  defp put_delivery_route(%Request{metadata: metadata} = request, route) do
    %{request | metadata: Map.put(metadata || %{}, "delivery", Atom.to_string(route))}
  end

  defp matches_delivery?(_request, nil), do: true

  defp matches_delivery?(%Request{metadata: metadata}, route) do
    Map.get(metadata || %{}, "delivery") == Atom.to_string(route)
  end

  defp add_pending(%__MODULE__{} = state, %Request{} = request) do
    key = session_scope_key(request.workspace, request.session_key)

    queue = :queue.in(request.id, Map.get(state.pending_by_session, key, :queue.new()))

    %{
      state
      | pending_by_session: Map.put(state.pending_by_session, key, queue),
        pending_by_id: Map.put(state.pending_by_id, request.id, request)
    }
  end

  defp peek_pending(state, workspace, session_key) do
    case pending_requests(state, workspace, session_key) do
      [request | _] -> {:ok, request}
      [] -> {:error, :no_pending_request}
    end
  end

  defp pop_all_pending(state, workspace, session_key) do
    requests = pending_requests(state, workspace, session_key)
    key = session_scope_key(workspace, session_key)
    ids = MapSet.new(Enum.map(requests, & &1.id))

    state = %{
      state
      | pending_by_session: Map.delete(state.pending_by_session, key),
        pending_by_id: Map.drop(state.pending_by_id, MapSet.to_list(ids))
    }

    {requests, state}
  end

  defp pop_pending_by_id(state, workspace, session_key, id) do
    key = session_scope_key(workspace, session_key)
    request = Map.get(state.pending_by_id, id)
    queue = Map.get(state.pending_by_session, key, :queue.new())
    queue = queue_without_id(queue, id)

    pending_by_session =
      if :queue.is_empty(queue),
        do: Map.delete(state.pending_by_session, key),
        else: Map.put(state.pending_by_session, key, queue)

    {request,
     %{
       state
       | pending_by_session: pending_by_session,
         pending_by_id: Map.delete(state.pending_by_id, id)
     }}
  end

  defp queue_without_id(queue, id) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1 == id))
    |> Enum.reduce(:queue.new(), &:queue.in/2)
  end

  defp pending_requests(state, workspace, session_key) do
    key = session_scope_key(workspace, session_key)

    state.pending_by_session
    |> Map.get(key, :queue.new())
    |> :queue.to_list()
    |> Enum.flat_map(fn id ->
      case Map.get(state.pending_by_id, id) do
        %Request{} = request -> [request]
        _ -> []
      end
    end)
  end

  defp pending_by_request_id(state, request_id) when is_binary(request_id) do
    case Map.get(state.pending_by_id, request_id) do
      %Request{} = request -> {:ok, request}
      _ -> {:error, :no_pending_request}
    end
  end

  defp pending_by_request_id(_state, _request_id), do: {:error, :no_pending_request}

  defp authorized_resolution?(%Request{} = request, opts) do
    authorize_resolution(request, opts) == :ok
  end

  defp authorize_resolution(%Request{authorized_actor: actor}, _opts)
       when actor in [nil, %{}],
       do: :ok

  defp authorize_resolution(%Request{authorized_actor: expected}, opts) when is_map(expected) do
    actor = resolution_actor(opts)

    if actor_matches?(expected, actor) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp resolution_actor(opts) when is_list(opts) do
    Keyword.get(opts, :authorized_actor) || Keyword.get(opts, :actor)
  end

  defp resolution_actor(opts) when is_map(opts) do
    Map.get(opts, :authorized_actor) ||
      Map.get(opts, "authorized_actor") ||
      Map.get(opts, :actor) ||
      Map.get(opts, "actor")
  end

  defp resolution_actor(_opts), do: nil

  defp actor_matches?(expected, actual) when is_map(expected) and is_map(actual) do
    expected_principal = actor_principal(expected)
    actual_principal = actor_principal(actual)

    present?(expected_principal) and expected_principal == actual_principal and
      actor_field_matches?(expected, actual, ["channel", "platform"]) and
      actor_field_matches?(expected, actual, ["chat_id"])
  end

  defp actor_matches?(_expected, _actual), do: false

  defp actor_principal(actor) when is_map(actor) do
    actor_value(actor, ["user_id", "sender_id", "id"])
  end

  defp actor_principal(_actor), do: nil

  defp actor_field_matches?(expected, actual, keys) do
    expected_value = actor_value(expected, keys)
    actual_value = actor_value(actual, keys)

    is_nil(expected_value) or is_nil(actual_value) or expected_value == actual_value
  end

  defp actor_value(actor, keys) when is_map(actor) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(actor, key) || Map.get(actor, String.to_atom(key)) do
        value when is_binary(value) ->
          value = String.trim(value)
          if value == "", do: nil, else: value

        value when is_atom(value) and not is_nil(value) ->
          Atom.to_string(value)

        value when is_integer(value) ->
          Integer.to_string(value)

        _ ->
          nil
      end
    end)
  end

  defp actor_value(_actor, _keys), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp pop_requests(state, requests) when is_list(requests) do
    Enum.reduce(requests, state, fn %Request{} = request, acc ->
      {_request, acc} = pop_pending_by_id(acc, request.workspace, request.session_key, request.id)
      acc
    end)
  end

  defp grant_spec_for_choice(%Request{} = request, :once) do
    cond do
      request.kind == :runtime_env ->
        {:error, :runtime_env_approval_requires_workspace_rule}

      rule_approval_required?(request) ->
        {:error, :permission_approval_requires_rule}

      true ->
        {:ok, :once}
    end
  end

  defp grant_spec_for_choice(%Request{kind: :runtime_env}, choice)
       when choice in [:session, :similar] do
    {:error, :runtime_env_approval_requires_workspace_rule}
  end

  defp grant_spec_for_choice(%Request{} = request, :similar) do
    case similar_grant_option(request) do
      nil ->
        {:error, :no_permission_rule_option}

      %{"rule" => rule} = option ->
        {:ok, {:session_rule, rule, option["subject"] || request.subject}}

      _option ->
        {:error, :permission_approval_requires_rule}
    end
  end

  defp grant_spec_for_choice(%Request{} = request, :session) do
    case exact_rule_option(request) do
      nil -> {:error, :permission_approval_requires_rule}
      option -> {:ok, {:session_rule, option["rule"], option["subject"] || request.subject}}
    end
  end

  defp grant_spec_for_choice(%Request{} = request, :always) do
    case exact_rule_option(request) do
      nil -> {:error, :permission_approval_requires_rule}
      option -> {:ok, {:always_rule, option["rule"], option["subject"] || request.subject}}
    end
  end

  defp exact_rule_option(%Request{} = request) do
    Enum.find(request.grant_options, fn option ->
      option["level"] == "exact" and is_map(option["rule"])
    end)
  end

  defp similar_grant_option(%Request{} = request) do
    Enum.find(request.grant_options, fn option ->
      grant_key = option["grant_key"] || ""

      option["level"] == "similar" or option["scope"] == "similar" or
        String.contains?(grant_key, ":family:")
    end)
  end

  defp apply_grant_spec(state, _workspace, _session_key, _request, :once) do
    {:ok, state, nil}
  end

  defp apply_grant_spec(
         state,
         workspace,
         session_key,
         %Request{} = request,
         {:session_rule, rule, subject}
       ) do
    rule = rule_from_grant(request, rule)

    grant = rule_grant_summary(request, rule, :session, subject)

    existing_rules =
      session_rules(state, workspace, session_key) ++ always_rules(state, workspace)

    with :ok <- PermissionRule.validate_new_rule(rule, existing_rules) do
      state = put_session_rule(state, workspace, session_key, rule)
      {:ok, state, grant}
    end
  end

  defp apply_grant_spec(
         state,
         workspace,
         _session_key,
         %Request{} = request,
         {:always_rule, rule, subject}
       ) do
    rule = rule_from_grant(request, rule)

    grant = rule_grant_summary(request, rule, :always, subject)

    with :ok <- PermissionRule.validate_new_rule(rule, always_rules(state, workspace)) do
      state = put_always_rule(state, workspace, rule)

      with :ok <- PermissionRuleStore.save(workspace, always_rules(state, workspace)) do
        {:ok, state, grant}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp rule_grant_summary(%Request{} = request, rule, scope, subject) do
    %{
      "kind" => "permission_rule",
      "operation" => Atom.to_string(request.operation),
      "subject" => subject,
      "grant_key" => PermissionRule.grant_key(rule),
      "scope" => Atom.to_string(scope),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp decision_in_state(state, workspace, session_key, %Request{} = request) do
    rules = session_rules(state, workspace, session_key) ++ always_rules(state, workspace)

    case PermissionRule.decide(PermissionRule.event_from_request(request), rules).action do
      :allow -> :allow
      :deny -> :deny
      :ask -> :ask
    end
  end

  defp decision_in_state(_state, _workspace, _session_key, request_or_grant_key)
       when is_binary(request_or_grant_key) do
    :ask
  end

  defp decision_in_state(_state, _workspace, _session_key, _request_or_grant_key), do: :ask

  defp approved_in_state?(state, workspace, session_key, request_or_grant_key) do
    decision_in_state(state, workspace, session_key, request_or_grant_key) == :allow
  end

  defp sweep_approved_pending(_state, _workspace, _session_key, nil), do: []

  defp sweep_approved_pending(state, workspace, session_key, grant) do
    scope = Map.get(grant, "scope")
    workspace = Path.expand(workspace)

    state.pending_by_id
    |> Map.values()
    |> Enum.filter(fn %Request{} = request ->
      same_workspace = Path.expand(request.workspace) == workspace

      same_scope =
        case scope do
          "always" -> true
          _ -> request.session_key == session_key
        end

      same_workspace and same_scope and
        approved_in_state?(state, request.workspace, request.session_key, request)
    end)
  end

  defp put_session_rule(state, workspace, session_key, rule) do
    workspace = Path.expand(workspace)
    rule = PermissionRule.Rule.new(rule)

    session_table =
      state.session_rules
      |> Map.get(workspace, %{})
      |> Map.update(session_key, [rule], &uniq_rules([rule | &1]))

    %{state | session_rules: Map.put(state.session_rules, workspace, session_table)}
  end

  defp session_rules(state, workspace, session_key) do
    state.session_rules
    |> Map.get(Path.expand(workspace), %{})
    |> Map.get(session_key, [])
  end

  defp rule_entries(state, workspace, session_key) do
    session_entries =
      state
      |> session_rules(workspace, session_key)
      |> Enum.map(&rule_entry(&1, :session))

    always_entries =
      state
      |> always_rules(workspace)
      |> Enum.map(&rule_entry(&1, :always))

    session_entries ++ always_entries
  end

  defp rule_entry(rule, persistence) do
    rule = PermissionRule.Rule.new(rule)

    %{
      rule_ref: PermissionRule.grant_key(rule),
      persistence: persistence,
      rule: rule
    }
  end

  defp revoke_rule_in_state(state, workspace, session_key, rule_ref) do
    workspace = Path.expand(workspace)

    with {:ok, persistence, rule} <- find_revocable_rule(state, workspace, session_key, rule_ref),
         :ok <- validate_revocable_rule(rule) do
      case persistence do
        :session ->
          {:ok, revoke_session_rule(state, workspace, session_key, rule_ref),
           rule_entry(rule, :session)}

        :always ->
          rules = always_rules(state, workspace)
          remaining = Enum.reject(rules, &(PermissionRule.grant_key(&1) == rule_ref))

          with :ok <- PermissionRuleStore.save(workspace, remaining) do
            {:ok, %{state | always_rules: Map.put(state.always_rules, workspace, remaining)},
             rule_entry(rule, :always)}
          end
      end
    end
  end

  defp find_revocable_rule(state, workspace, session_key, rule_ref) do
    session_rule =
      state
      |> session_rules(workspace, session_key)
      |> Enum.find(&(PermissionRule.grant_key(&1) == rule_ref))

    always_rule =
      state
      |> always_rules(workspace)
      |> Enum.find(&(PermissionRule.grant_key(&1) == rule_ref))

    cond do
      session_rule -> {:ok, :session, session_rule}
      always_rule -> {:ok, :always, always_rule}
      true -> {:error, :permission_rule_not_found}
    end
  end

  defp validate_revocable_rule(%PermissionRule.Rule{
         effect: :allow,
         level: 0,
         source: :owner_grant
       }),
       do: :ok

  defp validate_revocable_rule(%PermissionRule.Rule{effect: effect}) when effect != :allow,
    do: {:error, :permission_rule_revoke_cannot_remove_non_allow_rule}

  defp validate_revocable_rule(_rule), do: {:error, :permission_rule_revoke_not_allowed}

  defp revoke_session_rule(state, workspace, session_key, rule_ref) do
    workspace = Path.expand(workspace)

    session_table =
      state.session_rules
      |> Map.get(workspace, %{})
      |> Map.update(session_key, [], fn rules ->
        Enum.reject(rules, &(PermissionRule.grant_key(&1) == rule_ref))
      end)
      |> drop_empty_session_rules(session_key)

    session_rules =
      if map_size(session_table) == 0,
        do: Map.delete(state.session_rules, workspace),
        else: Map.put(state.session_rules, workspace, session_table)

    %{state | session_rules: session_rules}
  end

  defp drop_empty_session_rules(session_table, session_key) do
    case Map.get(session_table, session_key) do
      [] -> Map.delete(session_table, session_key)
      _rules -> session_table
    end
  end

  defp delete_session_rules(session_rules, workspace, session_key) do
    workspace = Path.expand(workspace)

    case Map.get(session_rules, workspace) do
      nil ->
        session_rules

      sessions ->
        sessions = Map.delete(sessions, session_key)

        if map_size(sessions) == 0,
          do: Map.delete(session_rules, workspace),
          else: Map.put(session_rules, workspace, sessions)
    end
  end

  defp put_always_rule(state, workspace, rule) do
    workspace = Path.expand(workspace)
    rule = PermissionRule.Rule.new(rule)
    rules = state.always_rules |> Map.get(workspace, []) |> then(&uniq_rules([rule | &1]))
    %{state | always_rules: Map.put(state.always_rules, workspace, rules)}
  end

  defp always_rules(state, workspace) do
    Map.get(state.always_rules, Path.expand(workspace), [])
  end

  defp uniq_rules(rules) do
    Enum.uniq_by(rules, &PermissionRule.grant_key/1)
  end

  defp ensure_workspace_loaded(state, workspace) do
    workspace = Path.expand(workspace)

    if MapSet.member?(state.loaded_workspaces, workspace) do
      state
    else
      rules = load_always_rules(workspace)

      %{
        state
        | always_rules: Map.put(state.always_rules, workspace, rules),
          loaded_workspaces: MapSet.put(state.loaded_workspaces, workspace)
      }
    end
  end

  defp rule_from_grant(%Request{} = request, rule) when is_map(rule) do
    rule
    |> Map.put("created_at", DateTime.utc_now() |> DateTime.to_iso8601())
    |> Map.put("created_by", request.authorized_actor)
    |> PermissionRule.Rule.new()
  end

  defp rule_from_grant(%Request{} = _request, rule), do: PermissionRule.Rule.new(rule)

  defp rule_approval_required?(%Request{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "requires_rule_approval") == true or
      Map.get(metadata, :requires_rule_approval) == true
  end

  defp rule_approval_required?(_request), do: false

  defp load_always_rules(workspace) do
    case PermissionRuleStore.load(workspace) do
      {:ok, rules} ->
        uniq_rules(rules)

      {:error, {:tampered, reason}, valid_prefix} ->
        Logger.warning(
          "[Sandbox.Approval] Permission rules tamper detected for #{workspace}: #{inspect(reason)}"
        )

        Log.warning(
          "permission.rules.tamper_detected",
          %{"reason" => inspect(reason), "valid_prefix_count" => length(valid_prefix)},
          context: %{workspace: workspace},
          workspace: workspace
        )

        uniq_rules(valid_prefix)
    end
  end

  defp session_scope_key(workspace, session_key), do: {Path.expand(workspace), session_key}

  defp reply_request(%Request{from: nil}, _reply), do: :ok
  defp reply_request(%Request{from: from}, reply), do: GenServer.reply(from, reply)

  defp hide_from(%Request{} = request), do: %{request | from: nil}

  defp resolve_request(%Request{} = request, :approved, choice, grant) do
    reply_request(request, {:ok, :approved})
    observe_request("sandbox.approval.approved", request, approval_attrs(choice, grant))
    publish_resolved(request, :approved, choice, grant)
  end

  defp resolve_request(%Request{} = request, :denied, choice, grant) do
    reply_request(request, {:error, :denied})
    observe_request("sandbox.approval.denied", request, %{"choice" => choice})
    publish_resolved(request, :denied, choice, grant)
  end

  defp publish_request(%Request{channel: channel, chat_id: chat_id} = request)
       when is_binary(channel) and is_binary(chat_id) do
    if Process.whereis(Bus) do
      request
      |> OutboundApproval.payload(render_request(request))
      |> put_in([:metadata, "channel"], channel)
      |> put_in([:metadata, "chat_id"], chat_id)
      |> then(&Bus.publish(Outbound.topic_for_channel(channel), &1))
    end

    :ok
  end

  defp publish_request(_request), do: :ok

  defp notify_pending(%Request{} = request, opts) do
    case Keyword.get(opts, :on_pending) do
      fun when is_function(fun, 1) ->
        fun.(request)

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("[Sandbox.Approval] pending notification failed: #{inspect(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("[Sandbox.Approval] pending notification failed: #{inspect({kind, reason})}")

      :ok
  end

  defp publish_resolved(%Request{} = request, status, choice, grant) do
    if Process.whereis(Bus) do
      Bus.publish(:sandbox_approval_resolved, %{
        request_id: request.id,
        workspace: request.workspace,
        session_key: request.session_key,
        channel: request.channel,
        chat_id: request.chat_id,
        status: status,
        choice: choice,
        grant: grant,
        request: hide_from(request)
      })
    end

    :ok
  end

  defp render_request(%Request{} = request) do
    [
      "Approval required: #{request.description}",
      approval_rule_hint(request),
      request_risk_hint(request),
      approval_command_help(request)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp approval_command_help(%Request{} = request) do
    command_approval_help(request)
  end

  defp command_approval_help(%Request{} = request) do
    approve_commands =
      maybe_once_approval_command(request) ++ maybe_rule_approval_command(request)

    "Use #{Enum.join(approve_commands, ", ")}, `/deny #{request.id}`, or `/deny all`."
  end

  defp maybe_once_approval_command(%Request{} = request) do
    if rule_approval_required?(request), do: [], else: ["`/approve #{request.id}`"]
  end

  defp maybe_rule_approval_command(%Request{} = request) do
    case OutboundApproval.recommended_rule_summary(request) do
      nil ->
        []

      _summary ->
        ["`/approve #{request.id} #{rule_approval_choice(request)}` (allow rule)"]
    end
  end

  defp rule_approval_choice(%Request{} = request) do
    if Enum.any?(request.grant_options, &similar_grant_option?/1) do
      :similar
    else
      case exact_rule_option(request) do
        %{"approval_choice" => "always"} -> :always
        %{"scope" => "always"} -> :always
        _option -> :session
      end
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

  defp approval_rule_hint(%Request{} = request),
    do: OutboundApproval.recommended_rule_summary(request)

  defp approval_attrs(choice, nil), do: %{"choice" => Atom.to_string(choice)}

  defp approval_attrs(choice, grant) do
    %{
      "choice" => Atom.to_string(choice),
      "grant_scope" => Map.get(grant, "scope"),
      "grant_kind" => Map.get(grant, "kind")
    }
  end

  defp observe_request(tag, %Request{} = request, attrs) do
    Log.info(
      tag,
      %{
        "request_id" => request.id,
        "kind" => Atom.to_string(request.kind),
        "operation" => Atom.to_string(request.operation)
      }
      |> Map.merge(stringify_observe_attrs(attrs)),
      context: %{
        workspace: request.workspace,
        session_key: request.session_key,
        channel: request.channel,
        chat_id: request.chat_id
      },
      workspace: request.workspace
    )
  end

  defp stringify_observe_attrs(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp observe_rule_revoked(workspace, session_key, %{
         rule_ref: rule_ref,
         persistence: persistence
       }) do
    Log.info(
      "permission.rule.revoked",
      %{
        "rule_ref" => rule_ref,
        "persistence" => Atom.to_string(persistence)
      },
      context: %{workspace: workspace, session_key: session_key},
      workspace: workspace
    )
  end
end
