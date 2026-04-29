defmodule Nex.Agent.Extension.Plugin.Contribution do
  @moduledoc """
  Normalization for active plugin contribution records.
  """

  alias Nex.Agent.Extension.Plugin.Manifest

  @active_kinds %{
    "channels" => "channel",
    "providers" => "provider",
    "tools" => "tool",
    "skills" => "skill",
    "commands" => "command"
  }

  @deferred_kinds ~w(workbench_apps workbench_views subagents)

  @spec normalize(Manifest.t()) :: {map(), [map()]}
  def normalize(%Manifest{} = manifest) do
    Enum.reduce(manifest.contributes || %{}, {empty_contributions(), []}, fn {kind, entries},
                                                                             {contribs, diags} ->
      cond do
        Map.has_key?(@active_kinds, kind) ->
          normalize_active_kind(manifest, kind, entries, contribs, diags)

        kind in @deferred_kinds ->
          {contribs, [diagnostic(manifest, "deferred_contribution_kind", kind) | diags]}

        true ->
          {contribs, [diagnostic(manifest, "unknown_contribution_kind", kind) | diags]}
      end
    end)
  end

  @spec empty_contributions() :: map()
  def empty_contributions do
    %{
      "channels" => [],
      "providers" => [],
      "tools" => [],
      "skills" => [],
      "commands" => []
    }
  end

  @spec merge(map(), map()) :: map()
  def merge(left, right) do
    Map.new(empty_contributions(), fn {kind, []} ->
      {kind, Map.get(left, kind, []) ++ Map.get(right, kind, [])}
    end)
  end

  defp normalize_active_kind(manifest, kind, entries, contribs, diagnostics)
       when is_list(entries) do
    {records, entry_diagnostics} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {entry, index}, {records, diags} ->
        case normalize_entry(manifest, kind, entry, index) do
          {:ok, record} -> {[record | records], diags}
          {:error, diagnostic} -> {records, [diagnostic | diags]}
        end
      end)

    {Map.update!(contribs, kind, &(Enum.reverse(records) ++ &1)),
     entry_diagnostics ++ diagnostics}
  end

  defp normalize_active_kind(manifest, kind, _entries, contribs, diagnostics) do
    {contribs, [diagnostic(manifest, "invalid_contribution_entries", kind) | diagnostics]}
  end

  defp normalize_entry(%Manifest{} = manifest, kind, %{} = attrs, index) do
    attrs = stringify_keys(attrs)
    contribution_id = contribution_id(kind, attrs, index)

    if contribution_id == "" do
      {:error, diagnostic(manifest, "missing_contribution_id", kind, index)}
    else
      {:ok,
       %{
         "kind" => Map.fetch!(@active_kinds, kind),
         "plugin_id" => manifest.id,
         "plugin_root" => plugin_root(manifest),
         "id" => contribution_id,
         "source" => Atom.to_string(manifest.source),
         "attrs" => attrs
       }}
    end
  end

  defp normalize_entry(manifest, kind, _entry, index) do
    {:error, diagnostic(manifest, "invalid_contribution_entry", kind, index)}
  end

  defp contribution_id("channels", attrs, _index), do: normalized_attr(attrs, "type")
  defp contribution_id("providers", attrs, _index), do: normalized_attr(attrs, "type")
  defp contribution_id("tools", attrs, _index), do: normalized_attr(attrs, "name")
  defp contribution_id("skills", attrs, _index), do: normalized_attr(attrs, "id")
  defp contribution_id("commands", attrs, _index), do: normalized_attr(attrs, "name")
  defp contribution_id(_kind, _attrs, index), do: Integer.to_string(index)

  defp plugin_root(%Manifest{path: path}) when is_binary(path), do: Path.dirname(path)
  defp plugin_root(_manifest), do: nil

  defp normalized_attr(attrs, key) do
    attrs
    |> Map.get(key, "")
    |> to_string()
    |> String.trim()
  end

  defp diagnostic(%Manifest{} = manifest, code, kind, index \\ nil) do
    %{
      "code" => code,
      "plugin_id" => manifest.id,
      "kind" => kind,
      "message" => diagnostic_message(code, kind)
    }
    |> maybe_put("index", index)
  end

  defp diagnostic_message("deferred_contribution_kind", kind),
    do: "contribution kind #{kind} is deferred until a runtime consumer exists"

  defp diagnostic_message("unknown_contribution_kind", kind),
    do: "contribution kind #{kind} is not supported"

  defp diagnostic_message("invalid_contribution_entries", kind),
    do: "contribution kind #{kind} must be a list"

  defp diagnostic_message("missing_contribution_id", kind),
    do: "contribution kind #{kind} is missing its id field"

  defp diagnostic_message("invalid_contribution_entry", kind),
    do: "contribution kind #{kind} entries must be objects"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} when is_binary(key) -> {key, stringify_value(value)}
      {key, value} -> {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
