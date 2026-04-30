defmodule Nex.Agent.SandboxCommandClassifierTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Sandbox.{CommandClassifier, Security}

  test "safe read commands can use similar family grants" do
    classification = CommandClassifier.classify("ls -la .")

    assert classification.risk_class == "read"
    assert classification.similar_safe?
    refute classification.requires_approval?
    assert classification.family_key == "command:execute:family:ls:list-files"
  end

  test "command substitution becomes high-risk exact approval instead of hard deny" do
    command = "D=$(echo ~/Desktop) && ls \"$D\""

    assert :ok = Security.validate_command(command)

    classification = CommandClassifier.classify(command)
    assert classification.risk_class == "command_substitution"
    assert classification.requires_approval?
    refute classification.similar_safe?
    assert classification.risk_hint =~ "nested command"
  end

  test "encoded shell pipelines are high-risk exact approval" do
    classification = CommandClassifier.classify("base64 -d payload.txt | sh")

    assert classification.risk_class == "encoded_shell"
    assert classification.requires_approval?
    refute classification.similar_safe?
    assert classification.risk_hint =~ "hidden script"
  end

  test "shell and interpreter escapes are high-risk exact approval" do
    shell = CommandClassifier.classify("bash -c 'echo hi'")
    ruby = CommandClassifier.classify("ruby -e 'puts 1'")

    assert shell.risk_class == "shell_escape"
    assert shell.requires_approval?
    refute shell.similar_safe?

    assert ruby.risk_class == "interpreter_code"
    assert ruby.requires_approval?
    refute ruby.similar_safe?
  end

  test "system-destructive commands remain hard-denied" do
    assert {:error, "Privilege escalation not allowed"} =
             Security.validate_command("echo hi | sudo sh")

    assert {:error, "Deleting from root not allowed"} = Security.validate_command("rm -rf /")
  end
end
