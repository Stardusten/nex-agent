defmodule Nex.Agent.Extension.Plugin.Catalog do
  @moduledoc """
  Runtime plugin catalog projection.
  """

  alias Nex.Agent.Runtime.Config
  alias Nex.Agent.Extension.Plugin.{Contribution, Manifest, Store}

  @spec runtime_data(keyword()) :: map()
  def runtime_data(opts \\ []) do
    plugin_config =
      case Keyword.get(opts, :config) do
        %Config{} = config -> Config.plugins_runtime(config)
        _ -> default_plugin_config()
      end

    %{"manifests" => manifests, "diagnostics" => load_diagnostics} = Store.load_all(opts)
    {enabled, enablement_diagnostics} = enabled_manifests(manifests, plugin_config)

    {contributions, contribution_diagnostics} =
      Enum.reduce(enabled, {Contribution.empty_contributions(), []}, fn manifest,
                                                                        {acc, diagnostics} ->
        {records, manifest_diagnostics} = Contribution.normalize(manifest)
        {Contribution.merge(acc, records), diagnostics ++ manifest_diagnostics}
      end)

    manifest_maps = Enum.map(manifests, &Manifest.to_map/1)
    enabled_ids = Enum.map(enabled, & &1.id)
    diagnostics = load_diagnostics ++ enablement_diagnostics ++ contribution_diagnostics

    %{
      manifests: manifest_maps,
      enabled: enabled_ids,
      contributions: contributions,
      diagnostics: diagnostics,
      hash: hash({manifest_maps, enabled_ids, contributions, diagnostics})
    }
  end

  @spec contributions(String.t() | atom(), keyword()) :: [map()]
  def contributions(kind, opts \\ []) do
    data = Keyword.get(opts, :plugins) || Keyword.get(opts, :plugin_data) || runtime_data(opts)
    contributions = Map.get(data, :contributions) || Map.get(data, "contributions") || %{}
    key = normalize_kind(kind)

    Map.get(contributions, key) || Map.get(contributions, atom_kind(key), [])
  end

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(kind), do: to_string(kind)

  defp atom_kind("channels"), do: :channels
  defp atom_kind("providers"), do: :providers
  defp atom_kind("tools"), do: :tools
  defp atom_kind("skills"), do: :skills
  defp atom_kind("commands"), do: :commands
  defp atom_kind(_kind), do: nil

  defp default_plugin_config, do: %{"disabled" => [], "enabled" => %{}}

  defp enabled_manifests(manifests, plugin_config) do
    disabled = MapSet.new(Map.get(plugin_config, "disabled", []))
    enabled_config = Map.get(plugin_config, "enabled", %{})

    Enum.reduce(manifests, {[], []}, fn %Manifest{} = manifest, {enabled, diagnostics} ->
      disabled? = MapSet.member?(disabled, manifest.id)
      config_enabled? = Map.get(enabled_config, manifest.id, false) == true

      diagnostic =
        if disabled? and Map.has_key?(enabled_config, manifest.id) do
          [enablement_conflict_diagnostic(manifest.id)]
        else
          []
        end

      effective? =
        manifest.enabled and not disabled? and
          (manifest.source == :builtin or config_enabled?)

      if effective? do
        {[manifest | enabled], diagnostics ++ diagnostic}
      else
        {enabled, diagnostics ++ diagnostic}
      end
    end)
    |> then(fn {enabled, diagnostics} -> {Enum.reverse(enabled), diagnostics} end)
  end

  defp enablement_conflict_diagnostic(plugin_id) do
    %{
      "code" => "plugin_enablement_conflict",
      "plugin_id" => plugin_id,
      "message" =>
        "plugin is disabled because disabled entries take precedence over enabled entries"
    }
  end

  defp hash(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
  end
end
