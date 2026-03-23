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
             request_options(workflow,
               method: :get,
               path: "/issues",
               params: [state: "open", labels: Enum.join(workflow.tracker.ready_labels, ",")]
             )
           ) do
      {:ok, Enum.map(List.wrap(response.body), &to_issue/1)}
    end
  end

  @spec issue(Workflow.t(), pos_integer(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def issue(%Workflow{} = workflow, issue_number, opts \\ []) when is_integer(issue_number) do
    request_fun = Keyword.get(opts, :request_fun, &default_request/1)

    with {:ok, response} <-
           request_fun.(
             request_options(workflow,
               method: :get,
               path: "/issues/#{issue_number}"
             )
           ) do
      {:ok, to_issue(response.body)}
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
             request_options(workflow,
               method: :patch,
               path: "/issues/#{issue_number}",
               json: %{labels: Enum.uniq(labels)}
             )
           ) do
      {:ok, to_issue(response.body)}
    end
  end

  defp request_options(workflow, opts) do
    path = Keyword.fetch!(opts, :path)
    url = "https://api.github.com/repos/#{workflow.tracker.owner}/#{workflow.tracker.repo}#{path}"
    method = Keyword.fetch!(opts, :method)
    params = Keyword.get(opts, :params)
    json = Keyword.get(opts, :json)

    [
      method: method,
      url: url,
      headers: request_headers(),
      params: params,
      json: json
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp request_headers do
    [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "nex-agent-orchestrator"}
    ]
    |> maybe_put_auth_header()
  end

  defp maybe_put_auth_header(headers) do
    case System.get_env("GH_TOKEN") || System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer #{token}"} | headers]

      _ ->
        headers
    end
  end

  defp default_request(options) do
    Req.request(options)
  end

  defp to_issue(body) when is_map(body) do
    %Issue{
      number: Map.get(body, "number"),
      title: Map.get(body, "title"),
      body: Map.get(body, "body"),
      html_url: Map.get(body, "html_url"),
      state: Map.get(body, "state"),
      labels:
        body
        |> Map.get("labels", [])
        |> Enum.map(fn
          %{"name" => name} -> name
          %{name: name} -> name
          name when is_binary(name) -> name
          other -> to_string(other)
        end)
    }
  end
end
