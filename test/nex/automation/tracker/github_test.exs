defmodule Nex.Automation.Tracker.GitHubTest do
  use ExUnit.Case, async: true

  alias Nex.Automation.Workflow
  alias Nex.Automation.Tracker.GitHub

  test "ready_issues requests open github issues with ready labels" do
    workflow = workflow_fixture()

    request_fun = fn options ->
      send(self(), {:request, options})

      {:ok,
       %{
         status: 200,
         body: [
           %{
             "number" => 42,
             "title" => "Automate this",
             "body" => "Please open a PR",
             "html_url" => "https://github.com/openai/symphony/issues/42",
             "state" => "open",
             "labels" => [%{"name" => "agent:ready"}]
           }
         ]
       }}
    end

    assert {:ok, [issue]} = GitHub.ready_issues(workflow, request_fun: request_fun)

    assert issue.number == 42
    assert issue.title == "Automate this"
    assert issue.labels == ["agent:ready"]

    assert_received {:request, options}
    assert options[:method] == :get
    assert options[:url] == "https://api.github.com/repos/openai/symphony/issues"
    assert options[:params] == [state: "open", labels: "agent:ready"]
  end

  test "ready_issues includes an authorization header when an auth token is available" do
    workflow = workflow_fixture()

    request_fun = fn options ->
      send(self(), {:request, options})
      {:ok, %{status: 200, body: []}}
    end

    assert {:ok, []} =
             GitHub.ready_issues(
               workflow,
               request_fun: request_fun,
               auth_token_fun: fn -> "token-123" end
             )

    assert_received {:request, options}

    assert {"authorization", "Bearer token-123"} in options[:headers]
  end

  test "ready_issues returns an error for non-success github responses" do
    workflow = workflow_fixture()

    request_fun = fn _options ->
      {:ok,
       %{
         status: 403,
         body: %{
           "message" => "API rate limit exceeded",
           "documentation_url" => "https://docs.github.com/rest"
         }
       }}
    end

    assert {:error, message} = GitHub.ready_issues(workflow, request_fun: request_fun)
    assert message =~ "403"
    assert message =~ "API rate limit exceeded"
  end

  test "mark_running swaps ready labels for the running label" do
    workflow = workflow_fixture()

    request_fun = fn options ->
      send(self(), {:request, options})

      {:ok,
       %{
         status: 200,
         body: %{
           "number" => 42,
           "title" => "Automate this",
           "body" => "Please open a PR",
           "html_url" => "https://github.com/openai/symphony/issues/42",
           "state" => "open",
           "labels" => [%{"name" => "nex:running"}]
         }
       }}
    end

    issue = %GitHub.Issue{number: 42, labels: ["agent:ready", "bug"]}

    assert {:ok, updated_issue} =
             GitHub.mark_running(workflow, issue, request_fun: request_fun)

    assert updated_issue.labels == ["nex:running"]

    assert_received {:request, options}
    assert options[:method] == :patch
    assert options[:url] == "https://api.github.com/repos/openai/symphony/issues/42"
    assert options[:json] == %{labels: ["bug", "nex:running"]}
  end

  defp workflow_fixture do
    %Workflow{
      tracker: %Workflow.Tracker{
        kind: :github,
        owner: "openai",
        repo: "symphony",
        ready_labels: ["agent:ready"],
        running_label: "nex:running",
        review_label: "nex:review",
        failed_label: "nex:failed"
      }
    }
  end
end
