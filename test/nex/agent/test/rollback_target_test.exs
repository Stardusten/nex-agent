defmodule Nex.Agent.Test.RollbackTargetTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Test.RollbackTarget

  test "value" do
    assert RollbackTarget.value() == :good
  end
end
