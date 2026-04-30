defmodule Nex.Agent.Sandbox.CommandClassifier do
  @moduledoc """
  Conservative command risk classifier for approval grant keys.

  This module does not enforce filesystem safety. It only describes the command
  well enough for approval once/session/similar semantics; OS sandboxing remains
  the execution boundary.
  """

  @safe_families %{
    "cat" => "read-file",
    "head" => "read-file",
    "tail" => "read-file",
    "less" => "read-file",
    "more" => "read-file",
    "ls" => "list-files",
    "pwd" => "list-files",
    "find" => "search-files",
    "grep" => "search-files",
    "rg" => "search-files",
    "wc" => "inspect-files",
    "file" => "inspect-files",
    "stat" => "inspect-files",
    "git" => "git-read"
  }

  @write_indicators [
    ">",
    ">>",
    "rm",
    "mv",
    "cp",
    "mkdir",
    "rmdir",
    "touch",
    "tee",
    "chmod",
    "chown",
    "install",
    "patch",
    "apply_patch"
  ]

  @network_programs ~w(curl wget nc netcat ncat ssh scp rsync ftp sftp)
  @shell_programs ~w(bash sh zsh fish csh tcsh dash ksh)
  @interpreter_programs ~w(python python3 ruby perl node php)

  @type classification :: %{
          required(:command) => String.t(),
          required(:program) => String.t() | nil,
          required(:risk_class) => String.t(),
          required(:exact_key) => String.t(),
          required(:risk_key) => String.t(),
          optional(:family_key) => String.t(),
          optional(:risk_hint) => String.t(),
          required(:requires_approval?) => boolean(),
          required(:similar_safe?) => boolean(),
          required(:summary) => String.t()
        }

  @spec classify(String.t()) :: classification()
  def classify(command) when is_binary(command) do
    normalized = command |> String.trim() |> normalize_spaces()
    tokens = shell_words(normalized)
    program = tokens |> first_program() |> normalize_program()
    {risk_class, risk_hint, requires_approval?} = risk_info(program, tokens, normalized)
    safe_family = safe_family(program, risk_class)

    base = %{
      command: normalized,
      program: program,
      risk_class: risk_class,
      exact_key: "command:execute:exact:#{digest(normalized)}",
      risk_key: "command:execute:risk:#{risk_class}",
      risk_hint: risk_hint,
      requires_approval?: requires_approval?,
      similar_safe?: is_binary(safe_family),
      summary: summary(program, risk_class, normalized)
    }

    if safe_family do
      Map.put(base, :family_key, "command:execute:family:#{program}:#{safe_family}")
    else
      base
    end
  end

  def classify(command), do: classify(to_string(command))

  defp shell_words(command) do
    Regex.scan(~r/"([^"\\]*(?:\\.[^"\\]*)*)"|'([^']*)'|[^\s]+/, command)
    |> Enum.map(fn
      [_full, double, ""] -> String.replace(double, "\\\"", "\"")
      [_full, "", single] -> single
      [full | _] -> full
    end)
  end

  defp first_program([]), do: nil

  defp first_program([first | rest]) do
    case first do
      "env" -> first_program(drop_env_assignments(rest))
      "command" -> first_program(rest)
      "exec" -> first_program(rest)
      "time" -> first_program(rest)
      _ -> first
    end
  end

  defp drop_env_assignments([token | rest]) do
    if String.contains?(token, "=") and not String.starts_with?(token, "-") do
      drop_env_assignments(rest)
    else
      [token | rest]
    end
  end

  defp drop_env_assignments([]), do: []

  defp normalize_program(nil), do: nil
  defp normalize_program(program), do: program |> Path.basename() |> String.downcase()

  defp risk_info(program, tokens, command) do
    cond do
      encoded_shell?(command) ->
        high_risk(
          "encoded_shell",
          "Decoded content is piped into a shell. Approve only if you trust the hidden script."
        )

      command_substitution?(command) ->
        high_risk(
          "command_substitution",
          "Command substitution runs a nested command before the main command."
        )

      process_substitution?(command) ->
        high_risk(
          "process_substitution",
          "Process substitution starts a hidden helper process and passes its output as a file."
        )

      shell_escape?(program, command) ->
        high_risk(
          "shell_escape",
          "This starts another shell, so the approved text may hide nested commands."
        )

      interpreter_one_liner?(program, tokens, command) ->
        high_risk(
          "interpreter_code",
          "Interpreter one-liners can read files, spawn processes, or run network code."
        )

      program in @network_programs ->
        {"network", nil, false}

      writes?(program, tokens, command) ->
        {"write", nil, false}

      program in Map.keys(@safe_families) ->
        {"read", nil, false}

      program in @interpreter_programs ->
        {"code", "General interpreter commands are approved exactly, not as a broad family.",
         false}

      true ->
        {"unknown", nil, false}
    end
  end

  defp high_risk(risk_class, hint), do: {risk_class, hint, true}

  defp encoded_shell?(command) do
    Regex.match?(
      ~r/(?:^|[;&|]\s*)(?:base64|openssl\s+base64)\b[\s\S]*\|\s*(?:bash|sh|zsh|fish|csh|tcsh|dash|ksh)\b/i,
      command
    )
  end

  defp command_substitution?(command) do
    Regex.match?(~r/`[^`]+`/, command) or Regex.match?(~r/\$\([^)]+\)/, command)
  end

  defp process_substitution?(command) do
    Regex.match?(~r/(^|[\s;&|])(?:<|>)\([^)]+\)/, command)
  end

  defp shell_escape?(program, command) do
    program in @shell_programs or
      Regex.match?(~r/[;&|]\s*(?:bash|sh|zsh|fish|csh|tcsh|dash|ksh)\b/i, command) or
      Regex.match?(
        ~r/\b(env|xargs|exec|nice|timeout)\s+.*\b(bash|sh|zsh|fish|csh|tcsh|dash|ksh)\b/i,
        command
      )
  end

  defp interpreter_one_liner?(program, tokens, command) do
    cond do
      program in ["python", "python3"] and Enum.any?(tokens, &(&1 == "-c")) ->
        true

      program in ["ruby", "perl", "node"] and Enum.any?(tokens, &(&1 == "-e")) ->
        true

      program == "php" and Enum.any?(tokens, &(&1 == "-r")) ->
        true

      Regex.match?(~r/\b(os\.system|subprocess|eval\(|exec\(|import\s+os)\b/i, command) ->
        true

      true ->
        false
    end
  end

  defp writes?(program, tokens, command) do
    program in @write_indicators or
      Enum.any?(tokens, &(&1 in [">", ">>"])) or
      String.contains?(command, " >") or
      String.contains?(command, ">>") or
      String.contains?(command, "| tee")
  end

  defp safe_family(program, "read"), do: Map.get(@safe_families, program)
  defp safe_family(_program, _risk_class), do: nil

  defp normalize_spaces(command) do
    Regex.replace(~r/\s+/, command, " ")
  end

  defp summary(nil, risk_class, command), do: "#{risk_class} command: #{command}"
  defp summary(program, risk_class, _command), do: "#{risk_class} command using #{program}"

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
