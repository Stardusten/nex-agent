defmodule Nex.Agent.ControlPlaneBudgetTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Observe.ControlPlane.{Budget, Query, Store}

  setup do
    workspace = tmp_workspace("budget")
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "current initializes stable budget state", %{workspace: workspace} do
    assert %{
             "capacity" => 100,
             "current" => 60,
             "mode" => "normal",
             "refill_rate" => 10,
             "spent_today" => 0
           } = Budget.current(workspace: workspace)

    assert File.exists?(Store.budget_path(workspace: workspace))
  end

  test "spend persists debit, writes metric, and rejects insufficient budget", %{
    workspace: workspace
  } do
    assert {:ok, ledger} = Budget.spend(:reflect_candidate, 8, workspace: workspace)
    assert ledger["current"] == 52
    assert ledger["spent_today"] == 8
    assert ledger["mode"] == "normal"

    assert {:error, :insufficient_budget} =
             Budget.spend("patch_proposal", 10_000, workspace: workspace)

    assert Budget.current(workspace: workspace)["current"] == 52

    assert [_spent] =
             Query.query(%{"tag" => "control_plane.budget.spent"}, workspace: workspace)

    assert [_insufficient] =
             Query.query(%{"tag" => "control_plane.budget.insufficient"}, workspace: workspace)
  end

  test "current refills over time up to capacity", %{workspace: workspace} do
    write_budget(workspace, %{
      "capacity" => 100,
      "current" => 20,
      "mode" => "normal",
      "refill_rate" => 10,
      "last_refilled_at" =>
        DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.to_iso8601(),
      "spent_today" => 30
    })

    assert %{"current" => 40, "mode" => "normal", "spent_today" => 30} =
             Budget.current(workspace: workspace)
  end

  test "mode follows current budget" do
    assert Budget.mode(%{"current" => 0}) == :sleep
    assert Budget.mode(%{"current" => 7}) == :low
    assert Budget.mode(%{"current" => 40}) == :normal
    assert Budget.mode(%{"current" => 90}) == :deep
  end

  defp write_budget(workspace, ledger) do
    path = Store.budget_path(workspace: workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(ledger))
  end

  defp tmp_workspace(name) do
    Path.join(
      System.tmp_dir!(),
      "nex-control-plane-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
