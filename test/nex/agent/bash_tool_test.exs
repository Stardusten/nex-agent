defmodule Nex.Agent.BashToolTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.Bash

  test "bash tool sanitizes non-utf8 command output" do
    assert {:ok, output} =
             Bash.execute(%{"command" => "printf '\\037\\213\\010\\000'"}, %{
               cwd: File.cwd!(),
               timeout: 2
             })

    assert is_binary(output)
    assert String.valid?(output)
    assert output =~ "Binary output"
  end
end
