defmodule Nex.Agent.Self.Update.TestTargets.RollbackTargetTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Self.Update.TestTargets.RollbackTarget

  test "value" do
    assert RollbackTarget.value() == :good
  end
end
