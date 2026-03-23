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
