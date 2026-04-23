defmodule Nex.Agent.Test.UpgradeTargetTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Test.UpgradeTarget

  test "value" do
    assert UpgradeTarget.value() == :v1
  end
end
