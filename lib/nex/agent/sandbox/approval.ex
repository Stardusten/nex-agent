defmodule Nex.Agent.Sandbox.Approval do
  @moduledoc """
  Deterministic approval state for sandbox and permission requests.

  Session grants are in-memory. Always grants are persisted under the workspace
  permissions directory. Requests are resolved FIFO per workspace/session.
  """

  use GenServer
  require Logger

  alias Nex.Agent.App.Bus
  alias Nex.Agent.Interface.Outbound
  alias Nex.Agent.Interface.Outbound.Approval, as: OutboundApproval
  alias Nex.Agent.Observe.ControlPlane.Log
  alias Nex.Agent.Runtime.Workspace
  alias Nex.Agent.Sandbox.Approval.{Grant, Request}
  require Log

  defstruct pending_by_session: %{},
            pending_by_id: %{},
            session_grants: %{},
            always_grants: %{},
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

  @spec approved?(String.t(), String.t(), Request.t() | String.t(), keyword()) :: boolean()
  def approved?(workspace, session_key, request_or_grant_key, opts \\ []) do
    GenServer.call(
      server(opts),
      {:approved?, Path.expand(workspace), session_key, request_or_grant_key}
    )
  end

  @spec grant_session(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def grant_session(workspace, session_key, grant, opts \\ []) do
    GenServer.call(
      server(opts),
      {:grant_session, Path.expand(workspace), session_key, grant},
      :infinity
    )
  end

  @spec grant_always(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def grant_always(workspace, grant, opts \\ []) do
    GenServer.call(server(opts), {:grant_always, Path.expand(workspace), grant}, :infinity)
  end

  @spec cancel_pending(String.t(), String.t(), atom(), keyword()) :: {:ok, map()}
  def cancel_pending(workspace, session_key, reason, opts \\ []) do
    GenServer.call(
      server(opts),
      {:cancel_pending, Path.expand(workspace), session_key, reason},
      :infinity
    )
  end

  @spec clear_session_grants(String.t(), String.t(), keyword()) :: :ok
  def clear_session_grants(workspace, session_key, opts \\ []) do
    GenServer.call(server(opts), {:clear_session_grants, Path.expand(workspace), session_key})
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

    if approved_in_state?(state, request.workspace, request.session_key, request) do
      {:reply, {:ok, :approved}, state}
    else
      request = %{request | from: from}
      state = add_pending(state, request)
      observe_request("sandbox.approval.requested", request, %{"status" => "pending"})
      notify_pending(request, opts)
      if Keyword.get(opts, :publish?, true), do: publish_request(request)
      {:noreply, state}
    end
  end

  def handle_call({:approve, workspace, session_key, :all, _opts}, _from, state) do
    state = ensure_workspace_loaded(state, workspace)
    {requests, state} = pop_all_pending(state, workspace, session_key)

    Enum.each(requests, &resolve_request(&1, :approved, :all, nil))

    {:reply, {:ok, %{approved: length(requests), granted: nil, choice: :all}}, state}
  end

  def handle_call({:approve, workspace, session_key, choice, _opts}, _from, state)
      when choice in [:once, :session, :similar, :always] do
    state = ensure_workspace_loaded(state, workspace)

    with {:ok, request} <- peek_pending(state, workspace, session_key),
         {:ok, grant_spec} <- grant_spec_for_choice(request, choice),
         {:ok, state, grant} <-
           apply_grant_spec(state, workspace, session_key, request, grant_spec) do
      {_request, state} = pop_pending_by_id(state, workspace, session_key, request.id)
      swept = sweep_approved_pending(state, workspace, session_key, grant)
      state = pop_requests(state, swept)

      resolve_request(request, :approved, choice, grant)
      Enum.each(swept, &resolve_request(&1, :approved, :grant, grant))

      {:reply, {:ok, %{approved: 1 + length(swept), granted: grant, choice: choice}}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:approve_request, request_id, choice, _opts}, _from, state)
      when choice in [:once, :session, :similar, :always] do
    with {:ok, request} <- pending_by_request_id(state, request_id),
         state <- ensure_workspace_loaded(state, request.workspace),
         {:ok, grant_spec} <- grant_spec_for_choice(request, choice),
         {:ok, state, grant} <-
           apply_grant_spec(state, request.workspace, request.session_key, request, grant_spec) do
      {_request, state} =
        pop_pending_by_id(state, request.workspace, request.session_key, request.id)

      swept = sweep_approved_pending(state, request.workspace, request.session_key, grant)
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

  def handle_call({:deny, workspace, session_key, :all, _opts}, _from, state) do
    {requests, state} = pop_all_pending(state, workspace, session_key)
    Enum.each(requests, &resolve_request(&1, :denied, :all, nil))
    {:reply, {:ok, %{denied: length(requests), choice: :all}}, state}
  end

  def handle_call({:deny, workspace, session_key, :once, _opts}, _from, state) do
    case pop_next_pending(state, workspace, session_key) do
      {:ok, request, state} ->
        resolve_request(request, :denied, :once, nil)
        {:reply, {:ok, %{denied: 1, choice: :once}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:deny_request, request_id, :once, _opts}, _from, state) do
    case pending_by_request_id(state, request_id) do
      {:ok, request} ->
        {_request, state} =
          pop_pending_by_id(state, request.workspace, request.session_key, request.id)

        resolve_request(request, :denied, :once, nil)
        {:reply, {:ok, %{denied: 1, choice: :once, request_id: request.id}}, state}

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

  def handle_call({:approved?, workspace, session_key, request_or_grant_key}, _from, state) do
    state = ensure_workspace_loaded(state, workspace)
    {:reply, approved_in_state?(state, workspace, session_key, request_or_grant_key), state}
  end

  def handle_call({:grant_session, workspace, session_key, grant}, _from, state) do
    case Grant.normalize(grant) do
      nil ->
        {:reply, {:error, :invalid_grant}, state}

      grant ->
        state = put_session_grant(state, workspace, session_key, grant)
        observe_grant("sandbox.approval.granted", workspace, session_key, grant)
        {:reply, {:ok, grant}, state}
    end
  end

  def handle_call({:grant_always, workspace, grant}, _from, state) do
    state = ensure_workspace_loaded(state, workspace)

    case Grant.normalize(grant) do
      nil ->
        {:reply, {:error, :invalid_grant}, state}

      grant ->
        state = put_always_grant(state, workspace, grant)

        case save_always_grants(workspace, always_grants(state, workspace)) do
          :ok ->
            observe_grant("sandbox.approval.granted", workspace, nil, grant)
            {:reply, {:ok, grant}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:cancel_pending, workspace, session_key, reason}, _from, state) do
    {requests, state} = pop_all_pending(state, workspace, session_key)
    Enum.each(requests, &reply_request(&1, {:error, {:cancelled, reason}}))
    Enum.each(requests, &observe_request("sandbox.approval.cancelled", &1, %{"reason" => reason}))
    {:reply, {:ok, %{cancelled: length(requests), reason: reason}}, state}
  end

  def handle_call({:clear_session_grants, workspace, session_key}, _from, state) do
    state = update_in(state.session_grants, &delete_session_grants(&1, workspace, session_key))
    {:reply, :ok, state}
  end

  def handle_call({:reset_session, workspace, session_key, reason}, _from, state) do
    {requests, state} = pop_all_pending(state, workspace, session_key)
    Enum.each(requests, &reply_request(&1, {:error, {:cancelled, reason}}))
    Enum.each(requests, &observe_request("sandbox.approval.cancelled", &1, %{"reason" => reason}))
    state = update_in(state.session_grants, &delete_session_grants(&1, workspace, session_key))
    {:reply, {:ok, %{cancelled: length(requests), cleared_session_grants: true}}, state}
  end

  defp normalize_request(%Request{} = request),
    do: %{request | workspace: Path.expand(request.workspace)}

  defp normalize_request(attrs), do: Request.new(attrs)

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

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

  defp pop_next_pending(state, workspace, session_key) do
    case peek_pending(state, workspace, session_key) do
      {:ok, request} ->
        {_request, state} = pop_pending_by_id(state, workspace, session_key, request.id)
        {:ok, request, state}

      {:error, reason} ->
        {:error, reason}
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

  defp pop_requests(state, requests) when is_list(requests) do
    Enum.reduce(requests, state, fn %Request{} = request, acc ->
      {_request, acc} = pop_pending_by_id(acc, request.workspace, request.session_key, request.id)
      acc
    end)
  end

  defp grant_spec_for_choice(_request, :once), do: {:ok, :once}

  defp grant_spec_for_choice(%Request{} = request, :session) do
    {:ok, {:session, request.grant_key, request.subject}}
  end

  defp grant_spec_for_choice(%Request{} = request, :always) do
    {:ok, {:always, request.grant_key, request.subject}}
  end

  defp grant_spec_for_choice(%Request{} = request, :similar) do
    case similar_grant_option(request) do
      nil -> {:error, :no_similar_grant_option}
      option -> {:ok, {:session, option["grant_key"], option["subject"] || request.subject}}
    end
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
         {:session, grant_key, subject}
       ) do
    grant = Grant.new(request, :session, grant_key: grant_key, subject: subject)
    {:ok, put_session_grant(state, workspace, session_key, grant), grant}
  end

  defp apply_grant_spec(
         state,
         workspace,
         _session_key,
         %Request{} = request,
         {:always, grant_key, subject}
       ) do
    grant = Grant.new(request, :always, grant_key: grant_key, subject: subject)
    state = put_always_grant(state, workspace, grant)

    case save_always_grants(workspace, always_grants(state, workspace)) do
      :ok -> {:ok, state, grant}
      {:error, reason} -> {:error, reason}
    end
  end

  defp approved_in_state?(state, workspace, session_key, %Request{} = request) do
    keys = request_grant_keys(request)
    grants = session_grants(state, workspace, session_key) ++ always_grants(state, workspace)
    Enum.any?(grants, &(Map.get(&1, "grant_key") in keys))
  end

  defp approved_in_state?(state, workspace, session_key, grant_key) when is_binary(grant_key) do
    grants = session_grants(state, workspace, session_key) ++ always_grants(state, workspace)
    Enum.any?(grants, &(Map.get(&1, "grant_key") == grant_key))
  end

  defp approved_in_state?(_state, _workspace, _session_key, _request_or_grant_key), do: false

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

  defp request_grant_keys(%Request{} = request) do
    request.grant_options
    |> Enum.map(&Map.get(&1, "grant_key"))
    |> Enum.reject(&is_nil/1)
    |> then(&[request.grant_key | &1])
    |> Enum.uniq()
  end

  defp put_session_grant(state, workspace, session_key, grant) do
    workspace = Path.expand(workspace)

    session_table =
      state.session_grants
      |> Map.get(workspace, %{})
      |> Map.update(session_key, [grant], &uniq_grants([grant | &1]))

    %{state | session_grants: Map.put(state.session_grants, workspace, session_table)}
  end

  defp session_grants(state, workspace, session_key) do
    state.session_grants
    |> Map.get(Path.expand(workspace), %{})
    |> Map.get(session_key, [])
  end

  defp delete_session_grants(session_grants, workspace, session_key) do
    workspace = Path.expand(workspace)

    case Map.get(session_grants, workspace) do
      nil ->
        session_grants

      sessions ->
        sessions = Map.delete(sessions, session_key)

        if map_size(sessions) == 0,
          do: Map.delete(session_grants, workspace),
          else: Map.put(session_grants, workspace, sessions)
    end
  end

  defp put_always_grant(state, workspace, grant) do
    workspace = Path.expand(workspace)
    grants = state.always_grants |> Map.get(workspace, []) |> then(&uniq_grants([grant | &1]))
    %{state | always_grants: Map.put(state.always_grants, workspace, grants)}
  end

  defp always_grants(state, workspace) do
    Map.get(state.always_grants, Path.expand(workspace), [])
  end

  defp uniq_grants(grants) do
    Enum.uniq_by(grants, &Map.get(&1, "grant_key"))
  end

  defp ensure_workspace_loaded(state, workspace) do
    workspace = Path.expand(workspace)

    if MapSet.member?(state.loaded_workspaces, workspace) do
      state
    else
      grants = load_always_grants(workspace)

      %{
        state
        | always_grants: Map.put(state.always_grants, workspace, grants),
          loaded_workspaces: MapSet.put(state.loaded_workspaces, workspace)
      }
    end
  end

  defp load_always_grants(workspace) do
    path = grants_path(workspace)

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         grants when is_list(grants) <- grants_from_decoded(decoded) do
      grants
      |> Enum.map(&Grant.normalize/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(Map.get(&1, "scope") == "always"))
      |> uniq_grants()
    else
      false ->
        []

      error ->
        Logger.warning("[Sandbox.Approval] Could not load grants from #{path}: #{inspect(error)}")
        []
    end
  end

  defp grants_from_decoded(%{"grants" => grants}) when is_list(grants), do: grants
  defp grants_from_decoded(grants) when is_list(grants), do: grants
  defp grants_from_decoded(_decoded), do: []

  defp save_always_grants(workspace, grants) do
    Workspace.ensure!(workspace: workspace)
    path = grants_path(workspace)

    with {:ok, encoded} <- Jason.encode(%{"version" => 1, "grants" => grants}, pretty: true),
         :ok <- File.write(path, encoded) do
      :ok
    end
  rescue
    e -> {:error, e}
  end

  defp grants_path(workspace), do: Path.join([workspace, "permissions", "grants.json"])

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
      request_risk_hint(request),
      "Use `/approve #{request.id}`, `/approve #{request.id} session`, `/approve #{request.id} similar`, `/approve #{request.id} always`, `/deny #{request.id}`, or `/deny all`."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp request_risk_hint(%Request{metadata: %{"risk_hint" => hint}})
       when is_binary(hint) and hint != "" do
    "Risk: #{hint}"
  end

  defp request_risk_hint(_request), do: nil

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

  defp observe_grant(tag, workspace, session_key, grant) do
    Log.info(
      tag,
      %{
        "kind" => Map.get(grant, "kind"),
        "operation" => Map.get(grant, "operation"),
        "scope" => Map.get(grant, "scope")
      },
      context: %{workspace: workspace, session_key: session_key},
      workspace: workspace
    )
  end

  defp stringify_observe_attrs(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), to_string(value)} end)
  end
end
