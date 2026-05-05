defmodule Nex.Agent.Sandbox.PermissionRuleStore do
  @moduledoc """
  Tamper-evident on-disk store for workspace permission rules.

  Rules are written as a full JSONL hash chain plus a small manifest. This is
  not cryptographic authorization, but it makes plain-text edits detectable and
  gives the approval runtime a single durable rule source.
  """

  alias Nex.Agent.Runtime.Workspace
  alias Nex.Agent.Sandbox.PermissionRule
  alias Nex.Agent.Sandbox.PermissionRule.Rule

  @chain_version 1
  @genesis_hash String.duplicate("0", 64)

  @type load_result :: {:ok, [Rule.t()]} | {:error, {:tampered, term()}, [Rule.t()]}

  @spec load(String.t()) :: load_result()
  def load(workspace) do
    chain_path = chain_path(workspace)
    manifest_path = manifest_path(workspace)

    if File.exists?(chain_path), do: load_chain(chain_path, manifest_path), else: {:ok, []}
  end

  @spec save(String.t(), [Rule.t() | map() | keyword()]) :: :ok | {:error, term()}
  def save(workspace, rules) when is_list(rules) do
    Workspace.ensure!(workspace: workspace)
    rules = rules |> Enum.map(&Rule.new/1) |> Enum.uniq_by(&PermissionRule.grant_key/1)
    entries = build_entries(rules)
    chain_body = entries |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
    chain_body = if chain_body == "", do: "", else: chain_body <> "\n"

    manifest = %{
      "version" => @chain_version,
      "count" => length(entries),
      "last_hash" => last_hash(entries),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    chain_path = chain_path(workspace)
    manifest_path = manifest_path(workspace)

    with :ok <- atomic_write(chain_path, chain_body),
         {:ok, manifest_body} <- Jason.encode(manifest, pretty: true),
         :ok <- atomic_write(manifest_path, manifest_body) do
      :ok
    end
  rescue
    e -> {:error, e}
  end

  @spec paths(String.t()) :: %{chain: String.t(), manifest: String.t()}
  def paths(workspace) do
    %{chain: chain_path(workspace), manifest: manifest_path(workspace)}
  end

  defp load_chain(chain_path, manifest_path) do
    with {:ok, chain_body} <- File.read(chain_path),
         {:ok, manifest} <- load_manifest(manifest_path),
         {:ok, rules, verification} <- decode_chain(chain_body),
         :ok <- verify_manifest(manifest, verification) do
      {:ok, rules}
    else
      {:tampered, reason, rules} -> {:error, {:tampered, reason}, rules}
      {:error, reason} -> {:error, {:tampered, reason}, []}
    end
  end

  defp load_manifest(path) do
    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      false -> {:error, :missing_manifest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_chain(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, [], @genesis_hash, 0}, fn line, {:ok, rules, prev_hash, count} ->
      case Jason.decode(line) do
        {:ok, entry} ->
          decode_entry(entry, rules, prev_hash, count + 1)

        {:error, reason} ->
          {:halt, {:tampered, {:invalid_json, reason}, Enum.reverse(rules)}}
      end
    end)
    |> case do
      {:ok, rules, last_hash, count} ->
        {:ok, Enum.reverse(rules), %{count: count, last_hash: last_hash}}

      {:tampered, reason, rules} ->
        {:tampered, reason, rules}
    end
  end

  defp decode_entry(entry, rules, prev_hash, expected_seq) do
    rule = Map.get(entry, "rule")
    expected_hash = entry_hash(prev_hash, rule)

    cond do
      Map.get(entry, "version") != @chain_version ->
        {:halt, {:tampered, {:bad_version, Map.get(entry, "version")}, Enum.reverse(rules)}}

      Map.get(entry, "seq") != expected_seq ->
        {:halt, {:tampered, {:bad_seq, Map.get(entry, "seq")}, Enum.reverse(rules)}}

      Map.get(entry, "prev_hash") != prev_hash ->
        {:halt, {:tampered, {:bad_prev_hash, expected_seq}, Enum.reverse(rules)}}

      Map.get(entry, "hash") != expected_hash ->
        {:halt, {:tampered, {:bad_hash, expected_seq}, Enum.reverse(rules)}}

      true ->
        {:cont, {:ok, [Rule.new(rule) | rules], expected_hash, expected_seq}}
    end
  end

  defp verify_manifest(manifest, verification) do
    cond do
      Map.get(manifest, "version") != @chain_version ->
        {:error, {:bad_manifest_version, Map.get(manifest, "version")}}

      Map.get(manifest, "count") != verification.count ->
        {:error, {:manifest_count_mismatch, Map.get(manifest, "count"), verification.count}}

      Map.get(manifest, "last_hash") != verification.last_hash ->
        {:error, :manifest_hash_mismatch}

      true ->
        :ok
    end
  end

  defp build_entries(rules) do
    rules
    |> Enum.map(&PermissionRule.rule_to_map/1)
    |> Enum.with_index(1)
    |> Enum.reduce({[], @genesis_hash}, fn {rule, seq}, {entries, prev_hash} ->
      hash = entry_hash(prev_hash, rule)

      entry = %{
        "version" => @chain_version,
        "seq" => seq,
        "prev_hash" => prev_hash,
        "rule" => rule,
        "hash" => hash
      }

      {[entry | entries], hash}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp entry_hash(prev_hash, rule) do
    encoded_rule = Jason.encode!(rule)
    :crypto.hash(:sha256, prev_hash <> "\n" <> encoded_rule) |> Base.encode16(case: :lower)
  end

  defp last_hash([]), do: @genesis_hash
  defp last_hash(entries), do: entries |> List.last() |> Map.fetch!("hash")

  defp atomic_write(path, body) do
    tmp_path = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    with :ok <- File.write(tmp_path, body),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      error ->
        _ = File.rm(tmp_path)
        error
    end
  end

  defp chain_path(workspace), do: Path.join([workspace, "permissions", "rules.jsonl"])
  defp manifest_path(workspace), do: Path.join([workspace, "permissions", "rules.manifest.json"])
end
