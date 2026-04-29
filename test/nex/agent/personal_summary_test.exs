defmodule Nex.Agent.Workflow.PersonalSummaryTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Workflow.PersonalSummary

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-personal-summary-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "builds an explicit personal task summary", %{workspace: workspace} do
    summary = PersonalSummary.build("daily", workspace: workspace)

    assert summary =~ "Daily Personal Summary"
    assert summary =~ "Open tasks: 0"
    assert summary =~ "Completed tasks: 0"
  end
end
