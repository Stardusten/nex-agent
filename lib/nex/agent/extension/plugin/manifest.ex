defmodule Nex.Agent.Extension.Plugin.Manifest do
  @moduledoc """
  Normalized plugin manifest.
  """

  @id_regex ~r/^(builtin|workspace|project):[a-z][a-z0-9_.-]{1,79}$/
  @sources [:builtin, :workspace, :project]
  @max_text 500

  @type source :: :builtin | :workspace | :project

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          version: String.t(),
          enabled: boolean(),
          source: source(),
          description: String.t(),
          path: String.t() | nil,
          contributes: map(),
          metadata: map()
        }

  @enforce_keys [:id, :title, :version, :enabled, :source, :description]
  defstruct [
    :id,
    :title,
    :version,
    :enabled,
    :source,
    :description,
    :path,
    contributes: %{},
    metadata: %{}
  ]

  @spec normalize(map(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def normalize(attrs, opts \\ [])

  def normalize(attrs, opts) when is_map(attrs) and is_list(opts) do
    attrs = stringify_keys(attrs)
    source_hint = Keyword.get(opts, :source)

    with {:ok, source} <- normalize_source(Map.get(attrs, "source"), source_hint),
         {:ok, id} <- normalize_id(Map.get(attrs, "id"), source),
         {:ok, title} <- normalize_text(Map.get(attrs, "title"), "title", required?: true),
         {:ok, version} <- normalize_text(Map.get(attrs, "version", "0.1.0"), "version"),
         {:ok, enabled} <- normalize_enabled(Map.get(attrs, "enabled", true)),
         {:ok, description} <- normalize_text(Map.get(attrs, "description", ""), "description"),
         {:ok, contributes} <- normalize_contributes(Map.get(attrs, "contributes", %{})),
         {:ok, metadata} <- normalize_metadata(Map.get(attrs, "metadata", %{})) do
      {:ok,
       %__MODULE__{
         id: id,
         title: title,
         version: version,
         enabled: enabled,
         source: source,
         description: description,
         path: Keyword.get(opts, :path),
         contributes: contributes,
         metadata: metadata
       }}
    end
  end

  def normalize(_attrs, _opts), do: {:error, "manifest must be a JSON object"}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = manifest) do
    %{
      "id" => manifest.id,
      "title" => manifest.title,
      "version" => manifest.version,
      "enabled" => manifest.enabled,
      "source" => Atom.to_string(manifest.source),
      "description" => manifest.description,
      "path" => manifest.path,
      "contributes" => manifest.contributes,
      "metadata" => manifest.metadata
    }
  end

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(@id_regex, id)
  def valid_id?(_id), do: false

  @spec source_from_id(String.t()) :: source() | nil
  def source_from_id(id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      [source, _name] -> normalize_source_value(source)
      _ -> nil
    end
  end

  def source_from_id(_id), do: nil

  defp normalize_source(value, hint) do
    source = normalize_source_value(value) || normalize_source_value(hint)

    cond do
      source in @sources -> {:ok, source}
      true -> {:error, "source must be builtin, workspace, or project"}
    end
  end

  defp normalize_source_value(value) when is_atom(value) and value in @sources, do: value

  defp normalize_source_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "builtin" -> :builtin
      "workspace" -> :workspace
      "project" -> :project
      _ -> nil
    end
  end

  defp normalize_source_value(_value), do: nil

  defp normalize_id(id, source) when is_binary(id) do
    id = String.trim(id)

    cond do
      not valid_id?(id) ->
        {:error, "id must match ^(builtin|workspace|project):[a-z][a-z0-9_.-]{1,79}$"}

      source_from_id(id) != source ->
        {:error, "id source prefix must match manifest source"}

      true ->
        {:ok, id}
    end
  end

  defp normalize_id(_id, _source), do: {:error, "id is required"}

  defp normalize_text(value, field, opts \\ []) do
    required? = Keyword.get(opts, :required?, false)

    case normalize_string(value) do
      nil when required? ->
        {:error, "#{field} is required"}

      nil ->
        {:ok, ""}

      text ->
        cond do
          String.length(text) > @max_text ->
            {:error, "#{field} must be at most #{@max_text} characters"}

          contains_control?(text) ->
            {:error, "#{field} must not contain control characters"}

          true ->
            {:ok, text}
        end
    end
  end

  defp normalize_enabled(value) when value in [true, "true"], do: {:ok, true}
  defp normalize_enabled(value) when value in [false, "false"], do: {:ok, false}
  defp normalize_enabled(_value), do: {:error, "enabled must be a boolean"}

  defp normalize_contributes(%{} = contributes), do: {:ok, stringify_keys(contributes)}
  defp normalize_contributes(_contributes), do: {:error, "contributes must be a JSON object"}

  defp normalize_metadata(%{} = metadata), do: {:ok, stringify_keys(metadata)}
  defp normalize_metadata(_metadata), do: {:error, "metadata must be a JSON object"}

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

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalize_string(_value), do: nil

  defp contains_control?(value), do: String.match?(value, ~r/[\x00-\x1F\x7F]/)
end
