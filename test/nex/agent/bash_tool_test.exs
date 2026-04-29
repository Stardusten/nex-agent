defmodule Nex.Agent.BashToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Capability.Tool.Core.Bash

  test "bash tool sanitizes non-utf8 command output" do
    assert {:ok, output} =
             Bash.execute(%{"command" => "printf '\\037\\213\\010\\000'", "timeout" => 2}, %{
               cwd: File.cwd!()
             })

    assert is_binary(output)
    assert String.valid?(output)
    assert output =~ "Binary output"
  end

  test "bash tool returns error for non-zero exit codes" do
    assert {:error, message} =
             Bash.execute(%{"command" => "exit 7", "timeout" => 1}, %{cwd: File.cwd!()})

    assert message =~ "Exit code 7"
  end

  test "bash tool honors timeout from tool arguments" do
    assert {:error, message} =
             Bash.execute(%{"command" => "sleep 1", "timeout" => 0.1}, %{cwd: File.cwd!()})

    assert message =~ "timed out"
  end
end
