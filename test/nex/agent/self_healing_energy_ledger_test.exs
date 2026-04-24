defmodule Nex.Agent.SelfHealingEnergyLedgerTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.SelfHealing.{EnergyLedger, EventStore}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "nex-self-healing-energy-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "current initializes stable energy state", %{workspace: workspace} do
    assert %{
             "capacity" => 100,
             "current" => 60,
             "mode" => "normal",
             "refill_rate" => 10,
             "spent_today" => 0
           } = EnergyLedger.current(workspace: workspace)

    assert File.exists?(EventStore.energy_path(workspace: workspace))
  end

  test "spend persists successful debit and rejects insufficient energy", %{workspace: workspace} do
    assert {:ok, ledger} = EnergyLedger.spend(:reflect_candidate, 8, workspace: workspace)
    assert ledger["current"] == 52
    assert ledger["spent_today"] == 8
    assert ledger["mode"] == "normal"

    assert {:error, :insufficient_energy} =
             EnergyLedger.spend(:patch_proposal, 10_000, workspace: workspace)

    assert EnergyLedger.current(workspace: workspace)["current"] == 52
  end

  test "current refills energy over time up to capacity", %{workspace: workspace} do
    write_energy(workspace, %{
      "capacity" => 100,
      "current" => 20,
      "mode" => "normal",
      "refill_rate" => 10,
      "last_refilled_at" =>
        DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.to_iso8601(),
      "spent_today" => 30
    })

    ledger = EnergyLedger.current(workspace: workspace)

    assert ledger["current"] == 40
    assert ledger["mode"] == "normal"
    assert ledger["spent_today"] == 30

    assert %{"current" => 40} =
             EventStore.energy_path(workspace: workspace)
             |> File.read!()
             |> Jason.decode!()
  end

  test "refill caps at capacity", %{workspace: workspace} do
    write_energy(workspace, %{
      "capacity" => 100,
      "current" => 95,
      "mode" => "deep",
      "refill_rate" => 10,
      "last_refilled_at" =>
        DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.to_iso8601(),
      "spent_today" => 30
    })

    assert %{"current" => 100, "mode" => "deep"} = EnergyLedger.current(workspace: workspace)
  end

  test "mode follows current energy" do
    assert EnergyLedger.mode(%{"current" => 0}) == :sleep
    assert EnergyLedger.mode(%{"current" => 7}) == :low
    assert EnergyLedger.mode(%{"current" => 40}) == :normal
    assert EnergyLedger.mode(%{"current" => 90}) == :deep
  end

  defp write_energy(workspace, ledger) do
    path = EventStore.energy_path(workspace: workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(ledger))
  end
end
