defmodule Nex.Automation.Tracker.GitHub do
  @moduledoc false

  alias Nex.Automation.Workflow

  defmodule Issue do
    @moduledoc false

    defstruct [:number, :title, :body, :html_url, :state, labels: []]
  end

  @type request_fun :: (keyword() -> {:ok, map()} | {:error, term()})

  @spec ready_issues(Workflow.t(), keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def ready_issues(%Workflow{} = workflow, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/1)

    with {:ok, response} <-
           request_fun.(
             request_options(
               workflow,
               opts,
               method: :get,
               path: "/issues",
               params: [state: "open", labels: Enum.join(workflow.tracker.ready_labels, ",")]
             )
           ),
         {:ok, body} <- response_body(response, :list) do
      {:ok, Enum.map(body, &to_issue/1)}
    end
  end

  @spec issue(Workflow.t(), pos_integer(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def issue(%Workflow{} = workflow, issue_number, opts \\ []) when is_integer(issue_number) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/1)

    with {:ok, response} <-
           request_fun.(
             request_options(
               workflow,
               opts,
               method: :get,
               path: "/issues/#{issue_number}"
             )
           ),
         {:ok, body} <- response_body(response, :map) do
      {:ok, to_issue(body)}
    end
  end

  @spec mark_running(Workflow.t(), Issue.t(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def mark_running(%Workflow{} = workflow, %Issue{} = issue, opts \\ []) do
    labels =
      issue.labels
      |> Enum.reject(&(&1 in workflow.tracker.ready_labels))
      |> Enum.reject(&(&1 == workflow.tracker.running_label))
      |> Kernel.++([workflow.tracker.running_label])

    update_labels(workflow, issue.number, labels, opts)
  end

  @spec mark_review(Workflow.t(), Issue.t(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def mark_review(%Workflow{} = workflow, %Issue{} = issue, opts \\ []) do
    labels =
      issue.labels
      |> Enum.reject(&(&1 in workflow.tracker.ready_labels))
      |> Enum.reject(&(&1 in [workflow.tracker.running_label, workflow.tracker.failed_label]))
      |> Enum.reject(&(&1 == workflow.tracker.review_label))
      |> Kernel.++([workflow.tracker.review_label])

    update_labels(workflow, issue.number, labels, opts)
  end

  @spec mark_failed(Workflow.t(), Issue.t(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def mark_failed(%Workflow{} = workflow, %Issue{} = issue, opts \\ []) do
    labels =
      issue.labels
      |> Enum.reject(&(&1 in workflow.tracker.ready_labels))
      |> Enum.reject(&(&1 in [workflow.tracker.running_label, workflow.tracker.review_label]))
      |> Enum.reject(&(&1 == workflow.tracker.failed_label))
      |> Kernel.++([workflow.tracker.failed_label])

    update_labels(workflow, issue.number, labels, opts)
  end

  defp update_labels(workflow, issue_number, labels, opts) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/1)

    with {:ok, response} <-
           request_fun.(
             request_options(
               workflow,
               opts,
               method: :patch,
               path: "/issues/#{issue_number}",
               json: %{labels: Enum.uniq(labels)}
             )
           ),
         {:ok, body} <- response_body(response, :map) do
      {:ok, to_issue(body)}
    end
  end

  defp request_options(workflow, runtime_opts, opts) do
    path = Keyword.fetch!(opts, :path)
    url = "https://api.github.com/repos/#{workflow.tracker.owner}/#{workflow.tracker.repo}#{path}"
    method = Keyword.fetch!(opts, :method)
    params = Keyword.get(opts, :params)
    json = Keyword.get(opts, :json)

    [
      method: method,
      url: url,
      headers: request_headers(runtime_opts),
      params: params,
      json: json
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp request_headers(opts) do
    [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "nex-agent-orchestrator"}
    ]
    |> maybe_put_auth_header(opts)
  end

  defp maybe_put_auth_header(headers, opts) do
    auth_token_fun = Keyword.get(opts, :auth_token_fun, &default_auth_token/0)

    case auth_token_fun.() do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer #{token}"} | headers]

      _ ->
        headers
    end
  end

  defp default_auth_token do
    System.get_env("GH_TOKEN") ||
      System.get_env("GITHUB_TOKEN") ||
      gh_auth_token()
  end

  defp gh_auth_token do
    case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
      {token, 0} ->
        token = String.trim(token)
        if token == "", do: nil, else: token

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp default_request(options) do
    Req.request(options)
  end

  defp response_body(%{status: status, body: body}, expected_shape) when status in 200..299 do
    case {expected_shape, body} do
      {:list, list} when is_list(list) -> {:ok, list}
      {:map, map} when is_map(map) -> {:ok, map}
      {:list, _} -> {:error, "unexpected GitHub response shape: expected a list body"}
      {:map, _} -> {:error, "unexpected GitHub response shape: expected a map body"}
    end
  end

  defp response_body(%{status: status, body: body}, _expected_shape) do
    {:error, format_error(status, body)}
  end

  defp format_error(status, body) do
    message =
      case body do
        %{"message" => message} -> message
        %{message: message} -> message
        _ -> inspect(body)
      end

    "GitHub API request failed with status #{status}: #{message}"
  end

  defp to_issue(body) when is_map(body) do
    %Issue{
      number: map_get(body, "number"),
      title: map_get(body, "title"),
      body: map_get(body, "body"),
      html_url: map_get(body, "html_url"),
      state: map_get(body, "state"),
      labels:
        body
        |> map_get("labels", [])
        |> Enum.map(fn
          %{"name" => name} -> name
          %{name: name} -> name
          name when is_binary(name) -> name
          other -> to_string(other)
        end)
    }
  end

  defp map_get(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
  end
end
