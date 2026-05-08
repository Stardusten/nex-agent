defmodule Nex.Agent.Self.Update.Committer do
  @moduledoc false

  alias Nex.Agent.Observe.ControlPlane.{Log, Query}
  alias Nex.Agent.Runtime.{Config, Snapshot}
  alias Nex.Agent.Sandbox.Approval
  alias Nex.Agent.Sandbox.Approval.Request
  alias Nex.Agent.Sandbox.{Command, Exec, Policy}
  alias Nex.Agent.Self.CodeUpgrade
  alias Nex.Agent.Self.Evolution.Candidates
  alias Nex.Agent.Self.Update.ReleaseStore
  require Log

  @commit_timeout_ms 30_000
  @git_timeout_ms 10_000
  @max_git_output_bytes 12_000

  @spec status(map()) :: {:ok, map()} | {:error, String.t()}
  def status(ctx \\ %{}) when is_map(ctx) do
    with {:ok, repo} <- configured_repo(ctx),
         {:ok, git_root} <- git_root(repo.path) do
      consistency = consistency_status(repo, git_root)

      {:ok,
       %{
         status: :ok,
         configured: true,
         source_repo: repo.path,
         git_root: git_root,
         runtime_repo_root: CodeUpgrade.repo_root(),
         check_consistency: repo.check_consistency,
         consistent: consistency.consistent?,
         warnings: consistency.warnings
       }}
    else
      {:error, reason} ->
        {:ok,
         %{
           status: :ok,
           configured: false,
           source_repo: nil,
           git_root: nil,
           runtime_repo_root: CodeUpgrade.repo_root(),
           check_consistency: true,
           consistent: false,
           warnings: [reason]
         }}
    end
  end

  @spec configured?(map()) :: boolean()
  def configured?(ctx) when is_map(ctx) do
    match?({:ok, _repo}, configured_repo(ctx))
  end

  def configured?(_ctx), do: false

  @spec prepare(map(), map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def prepare(args, ctx, opts \\ []) when is_map(args) and is_map(ctx) do
    with {:ok, repo} <- configured_repo(ctx),
         {:ok, release_id} <- release_id(args),
         {:ok, release} <- ReleaseStore.load_release(release_id),
         :ok <- ensure_deployed_release(release),
         {:ok, git_root} <- git_root(repo.path),
         :ok <- ensure_consistency(repo, git_root, release),
         {:ok, candidate} <- candidate(args, release, ctx),
         evidence_ids <- evidence_ids(args, release, candidate),
         evidence <- evidence_summaries(evidence_ids, ctx),
         message <- build_message(release, candidate, evidence, evidence_ids, args),
         files <- release_files(release),
         {:ok, changed_files} <- changed_release_files(git_root, files) do
      proposal = %{
        status: :prepared,
        release_id: release_id,
        candidate_id: candidate && candidate["candidate_id"],
        evidence_ids: evidence_ids,
        source_repo: repo.path,
        git_root: git_root,
        check_consistency: repo.check_consistency,
        files: files,
        changed_files: changed_files,
        subject: first_line(message),
        message: message,
        evidence: evidence
      }

      if Keyword.get(opts, :emit?, true) do
        emit(:info, "source_repo.commit.proposed", proposal_attrs(proposal), ctx)
      end

      {:ok, proposal}
    else
      {:error, :enoent} ->
        {:error, "Release not found"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @spec prepare_from_deploy_result(map(), map(), map()) ::
          {:ok, map()} | :skip | {:error, String.t()}
  def prepare_from_deploy_result(%{status: :deployed, release_id: release_id}, args, ctx)
      when is_map(args) and is_map(ctx) do
    if configured?(ctx) do
      args
      |> Map.put_new("release_id", release_id)
      |> prepare(ctx, emit?: false)
    else
      :skip
    end
  end

  def prepare_from_deploy_result(_result, _args, _ctx), do: :skip

  @spec commit(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def commit(args, ctx) when is_map(args) and is_map(ctx) do
    with {:ok, proposal} <- prepare(args, ctx),
         :ok <- request_owner_approval(proposal, ctx),
         {:ok, commit_result} <- run_commit(proposal) do
      result = Map.merge(proposal, commit_result)
      emit(:info, "source_repo.commit.finished", proposal_attrs(result), ctx)
      {:ok, result}
    else
      {:error, :denied} ->
        {:error, "source repo commit was not approved"}

      {:error, {:cancelled, reason}} ->
        {:error, "source repo commit approval was cancelled: #{reason}"}

      {:error, reason} when is_binary(reason) ->
        _ = emit(:error, "source_repo.commit.failed", %{"error_summary" => reason}, ctx)
        {:error, reason}

      {:error, reason} ->
        reason = inspect(reason)
        _ = emit(:error, "source_repo.commit.failed", %{"error_summary" => reason}, ctx)
        {:error, reason}
    end
  end

  defp configured_repo(ctx) do
    source_repo =
      ctx
      |> config_from_ctx()
      |> Config.self_update_runtime()
      |> Map.get("source_repo", %{})

    case Map.get(source_repo, "path") do
      path when is_binary(path) and path != "" ->
        {:ok,
         %{
           path: Path.expand(path),
           check_consistency: Map.get(source_repo, "check_consistency", true)
         }}

      _ ->
        {:error, "self_update.source_repo.path is not configured"}
    end
  end

  defp config_from_ctx(%{config: %Config{} = config}), do: config
  defp config_from_ctx(%{"config" => %Config{} = config}), do: config
  defp config_from_ctx(%{runtime_snapshot: %Snapshot{config: %Config{} = config}}), do: config
  defp config_from_ctx(%{"runtime_snapshot" => %Snapshot{config: %Config{} = config}}), do: config
  defp config_from_ctx(_ctx), do: Config.default()

  defp release_id(%{"release_id" => release_id}) when is_binary(release_id) and release_id != "",
    do: {:ok, release_id}

  defp release_id(%{release_id: release_id}) when is_binary(release_id) and release_id != "",
    do: {:ok, release_id}

  defp release_id(_args), do: {:error, "release_id is required"}

  defp ensure_deployed_release(%{"status" => "deployed"}), do: :ok

  defp ensure_deployed_release(%{"id" => id, "status" => status}),
    do: {:error, "Release #{id} is not a deployed release: #{status}"}

  defp ensure_deployed_release(_release), do: {:error, "Invalid release record"}

  defp git_root(path) do
    with true <- File.dir?(path),
         {:ok, output} <- git(path, ["rev-parse", "--show-toplevel"]) do
      {:ok, output |> String.trim() |> canonical_path()}
    else
      false -> {:error, "Configured source repo path does not exist: #{path}"}
      {:error, reason} -> {:error, "Configured source repo is not a git worktree: #{reason}"}
    end
  end

  defp consistency_status(%{check_consistency: false}, _git_root) do
    %{consistent?: true, warnings: ["source repo consistency check disabled by config"]}
  end

  defp consistency_status(_repo, git_root) do
    runtime_root = CodeUpgrade.repo_root() |> canonical_path()

    if canonical_path(git_root) == runtime_root do
      %{consistent?: true, warnings: []}
    else
      %{
        consistent?: false,
        warnings: [
          "configured source repo git root #{git_root} does not match runtime repo root #{runtime_root}"
        ]
      }
    end
  end

  defp ensure_consistency(%{check_consistency: false}, _git_root, _release), do: :ok

  defp ensure_consistency(_repo, git_root, release) do
    runtime_root = CodeUpgrade.repo_root() |> canonical_path()

    cond do
      canonical_path(git_root) != runtime_root ->
        {:error,
         "Configured source repo git root #{git_root} does not match runtime repo root #{runtime_root}"}

      true ->
        verify_release_file_hashes(git_root, release)
    end
  end

  defp verify_release_file_hashes(git_root, release) do
    release
    |> Map.get("files", [])
    |> Enum.find_value(:ok, fn file ->
      relative_path = Map.get(file, "path")
      expected_sha = Map.get(file, "after_sha")
      path = Path.join(git_root, relative_path || "")

      cond do
        not is_binary(relative_path) or relative_path == "" ->
          {:error, "Release contains an invalid file path"}

        not File.regular?(path) ->
          {:error, "Release file is missing from configured source repo: #{relative_path}"}

        is_binary(expected_sha) and sha256(File.read!(path)) != expected_sha ->
          {:error, "Release file content does not match deployed after_sha: #{relative_path}"}

        true ->
          false
      end
    end)
  end

  defp candidate(args, release, ctx) do
    case text_value(args, "candidate_id") || Map.get(release, "candidate_id") do
      nil ->
        {:ok, nil}

      candidate_id ->
        case Candidates.get(candidate_id, workspace_opts(ctx)) do
          {:ok, candidate} -> {:ok, candidate}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp evidence_ids(args, release, candidate) do
    []
    |> Kernel.++(
      normalize_string_list(Map.get(args, "evidence_ids") || Map.get(args, :evidence_ids))
    )
    |> Kernel.++(normalize_string_list(Map.get(release, "evidence_ids")))
    |> Kernel.++(normalize_string_list(candidate && candidate["evidence_ids"]))
    |> Enum.uniq()
  end

  defp evidence_summaries([], _ctx), do: []

  defp evidence_summaries(evidence_ids, ctx) do
    limit = max(length(evidence_ids), 1)

    %{"id" => evidence_ids, "limit" => limit}
    |> Query.query(workspace_opts(ctx))
    |> Enum.map(&Query.observation_summary/1)
  end

  defp release_files(release) do
    release
    |> Map.get("files", [])
    |> Enum.map(&Map.get(&1, "path"))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp changed_release_files(_git_root, []), do: {:error, "Release has no files to commit"}

  defp changed_release_files(git_root, files) do
    case git(git_root, ["status", "--porcelain", "--" | files]) do
      {:ok, output} ->
        changed =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_porcelain_path/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        if changed == [] do
          {:error, "No source repo changes found for release files"}
        else
          {:ok, changed}
        end

      {:error, reason} ->
        {:error, "Unable to inspect source repo changes: #{reason}"}
    end
  end

  defp build_message(release, candidate, evidence, evidence_ids, args) do
    override = text_value(args, "message")

    if is_binary(override) and override != "" do
      normalize_commit_message(override)
    else
      subject =
        candidate_summary(candidate) ||
          Map.get(release, "reason") ||
          "self_update release #{short_id(Map.get(release, "id"))}"

      [
        commit_subject(subject),
        "",
        "self_update release: #{Map.get(release, "id")}",
        "candidate: #{(candidate && candidate["candidate_id"]) || "none"}",
        "reason: #{Map.get(release, "reason") || "none"}",
        "",
        "Files:",
        release_file_lines(release),
        "",
        "Tests:",
        release_test_lines(release),
        "",
        "ControlPlane evidence:",
        evidence_lines(evidence, evidence_ids)
      ]
      |> List.flatten()
      |> Enum.join("\n")
      |> normalize_commit_message()
    end
  end

  defp commit_subject(subject) do
    subject =
      subject
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    subject =
      if String.starts_with?(String.downcase(subject), "self_update:") do
        subject
      else
        "self_update: #{subject}"
      end

    String.slice(subject, 0, 72)
  end

  defp release_file_lines(release) do
    case Map.get(release, "files", []) do
      [] ->
        ["- none"]

      files ->
        Enum.map(files, fn file ->
          before_sha = file |> Map.get("before_sha", "") |> short_id()
          after_sha = file |> Map.get("after_sha", "") |> short_id()
          "- #{Map.get(file, "path")} #{before_sha} -> #{after_sha}"
        end)
    end
  end

  defp release_test_lines(release) do
    case Map.get(release, "tests", []) do
      [] ->
        ["- none"]

      tests ->
        Enum.map(tests, fn test ->
          "- #{Map.get(test, "path") || Map.get(test, :path)}: #{Map.get(test, "status") || Map.get(test, :status)}"
        end)
    end
  end

  defp evidence_lines([], []), do: ["- none"]
  defp evidence_lines([], evidence_ids), do: Enum.map(evidence_ids, &"- #{&1}: not found")

  defp evidence_lines(evidence, _evidence_ids) do
    Enum.map(evidence, fn item ->
      attrs = Map.get(item, "attrs_summary", %{})

      summary =
        attrs["summary"] || attrs["error_summary"] || attrs["reason"] || attrs["phase"] || ""

      suffix = if summary == "", do: "", else: " - #{summary}"
      "- #{item["id"]}: #{item["tag"]} #{item["level"]}#{suffix}"
    end)
  end

  defp normalize_commit_message(message) do
    message
    |> to_string()
    |> String.replace("\r\n", "\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp first_line(message) do
    message
    |> String.split("\n", parts: 2)
    |> List.first()
  end

  defp candidate_summary(nil), do: nil
  defp candidate_summary(candidate), do: text_value(candidate, "summary")

  defp request_owner_approval(proposal, ctx) do
    request =
      Request.new(%{
        kind: :command,
        operation: :execute,
        subject: "git commit #{proposal.release_id}",
        description: approval_description(proposal),
        grant_key: approval_grant_key(proposal),
        grant_options: [],
        workspace: workspace(ctx) || proposal.git_root,
        session_key: session_key(ctx) || "default",
        channel: text_value(ctx, "channel"),
        chat_id: text_value(ctx, "chat_id"),
        authorized_actor: actor(ctx),
        metadata: %{
          "risk_class" => "write",
          "risk_hint" => "Creates a Git commit in the configured local source repository.",
          "release_id" => proposal.release_id,
          "candidate_id" => proposal.candidate_id,
          "source_repo" => proposal.git_root,
          "files" => proposal.files,
          "commit_subject" => proposal.subject,
          "commit_message" => proposal.message
        }
      })

    emit(:info, "source_repo.commit.approval.requested", proposal_attrs(proposal), ctx)

    case Approval.request(request, approval_opts(ctx)) do
      {:ok, :approved} -> :ok
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  defp approval_description(proposal) do
    """
    Create source repo commit for self_update release #{proposal.release_id}

    Subject:
    #{proposal.subject}

    Files:
    #{Enum.map_join(proposal.files, "\n", &"- #{&1}")}
    """
    |> String.trim()
  end

  defp approval_grant_key(proposal) do
    digest = sha256("#{proposal.release_id}\n#{proposal.message}")
    "source_repo:commit:#{proposal.release_id}:#{digest}"
  end

  defp run_commit(%{git_root: git_root, files: files, message: message} = proposal) do
    with :ok <- ensure_no_staged_changes(git_root),
         {:ok, _} <- git(git_root, ["add", "--" | files]),
         {:ok, output} <-
           git(git_root, ["commit", "-F", "-"], stdin: message, timeout_ms: @commit_timeout_ms),
         {:ok, sha} <- git(git_root, ["rev-parse", "HEAD"]) do
      {:ok,
       %{
         status: :committed,
         commit_sha: String.trim(sha),
         commit_output: trim_output(output)
       }}
    else
      {:error, reason} ->
        _ = git(git_root, ["reset", "-q", "--" | proposal.files])
        {:error, reason}
    end
  end

  defp ensure_no_staged_changes(git_root) do
    case git(git_root, ["diff", "--cached", "--name-only"]) do
      {:ok, ""} ->
        :ok

      {:ok, output} ->
        {:error,
         "Source repo has staged changes; commit self_update release from a clean index first: #{String.trim(output)}"}

      {:error, reason} ->
        {:error, "Unable to inspect source repo index: #{reason}"}
    end
  end

  defp git(cwd, args, opts \\ []) do
    command = %Command{
      program: "git",
      args: args,
      cwd: cwd,
      stdin: Keyword.get(opts, :stdin),
      timeout_ms: Keyword.get(opts, :timeout_ms, @git_timeout_ms),
      metadata: %{workspace: cwd, observe_attrs: %{"source" => "source_repo.committer"}}
    }

    case Exec.run(command, internal_exec_policy()) do
      {:ok, %{stdout: output}} ->
        {:ok, output}

      {:error, %{stdout: output}} when is_binary(output) ->
        {:error, trim_output(output)}

      {:error, %{error: error}} when is_binary(error) ->
        {:error, error}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp internal_exec_policy do
    %Policy{
      enabled: false,
      backend: :noop,
      mode: :external,
      network: :restricted,
      filesystem: [],
      protected_paths: [],
      protected_names: [],
      env_allowlist: ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"],
      raw: %{}
    }
  end

  defp parse_porcelain_path(<<_status1, _status2, ?\s, rest::binary>>) do
    rest
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> case do
      "" -> nil
      path -> path
    end
  end

  defp parse_porcelain_path(_line), do: nil

  defp emit(level, tag, attrs, ctx) do
    opts = workspace_opts(ctx) ++ context_opts(ctx)

    case level do
      :error -> Log.error(tag, attrs, opts)
      _ -> Log.info(tag, attrs, opts)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp proposal_attrs(proposal) do
    %{
      "release_id" => proposal.release_id,
      "candidate_id" => proposal.candidate_id,
      "evidence_ids" => proposal.evidence_ids,
      "source_repo" => proposal.git_root || proposal.source_repo,
      "files" => proposal.files,
      "commit_subject" => proposal.subject,
      "commit_sha" => Map.get(proposal, :commit_sha)
    }
    |> compact_map()
  end

  defp workspace_opts(ctx) do
    case workspace(ctx) do
      nil -> []
      workspace -> [workspace: workspace]
    end
  end

  defp context_opts(ctx) do
    context =
      [:run_id, :session_key, :channel, :chat_id, :tool_call_id, :trace_id]
      |> Enum.reduce(%{}, fn key, acc ->
        case text_value(ctx, Atom.to_string(key)) do
          nil -> acc
          value -> Map.put(acc, Atom.to_string(key), value)
        end
      end)

    if context == %{}, do: [], else: [context: context]
  end

  defp workspace(ctx), do: text_value(ctx, "workspace")

  defp session_key(ctx) do
    text_value(ctx, "session_key") ||
      case {text_value(ctx, "channel"), text_value(ctx, "chat_id")} do
        {channel, chat_id} when is_binary(channel) and is_binary(chat_id) ->
          "#{channel}:#{chat_id}"

        _ ->
          nil
      end
  end

  defp approval_opts(ctx) do
    case Map.get(ctx, :approval_server) || Map.get(ctx, "approval_server") do
      nil -> []
      server -> [server: server]
    end
  end

  defp actor(ctx) do
    %{
      kind: :owner_run,
      channel: text_value(ctx, "channel"),
      id: text_value(ctx, "chat_id"),
      display: "agent"
    }
  end

  defp text_value(map, key) when is_map(map) and is_binary(key) do
    atom_key = String.to_existing_atom(key)

    case Map.get(map, key) || Map.get(map, atom_key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  rescue
    ArgumentError ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
  end

  defp text_value(_map, _key), do: nil

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_values), do: []

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp short_id(nil), do: "none"
  defp short_id(value), do: value |> to_string() |> String.slice(0, 12)

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp trim_output(output) when is_binary(output) do
    output = if String.valid?(output), do: output, else: inspect(output)

    if byte_size(output) > @max_git_output_bytes do
      binary_part(output, 0, @max_git_output_bytes) <>
        "\n... output truncated to #{@max_git_output_bytes} bytes"
    else
      String.trim(output)
    end
  end

  defp trim_output(output), do: inspect(output)

  defp canonical_path(path) do
    path = Path.expand(path)

    cond do
      File.dir?(path) ->
        File.cd!(path, &File.cwd!/0)

      File.exists?(path) ->
        Path.join(canonical_path(Path.dirname(path)), Path.basename(path))

      true ->
        path
    end
  rescue
    _error -> Path.expand(path)
  end
end
