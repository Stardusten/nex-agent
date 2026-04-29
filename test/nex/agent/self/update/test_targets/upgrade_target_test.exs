defmodule Nex.Agent.Self.Update.TestTargets.UpgradeTargetTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Self.Update.TestTargets.UpgradeTarget

  test "value" do
    assert UpgradeTarget.value() == :v1
  end
end
