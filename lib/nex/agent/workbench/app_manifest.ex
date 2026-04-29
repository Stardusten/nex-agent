defmodule Nex.Agent.Workbench.AppManifest do
  @moduledoc """
  Normalized manifest for one Workbench app.
  """

  @id_regex ~r/^[a-z][a-z0-9_-]{1,63}$/
  @max_permission_length 160

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          version: String.t(),
          entry: String.t(),
          permissions: [String.t()],
          metadata: map(),
          chrome: map()
        }

  @enforce_keys [:id, :title, :version, :entry, :permissions, :metadata, :chrome]
  defstruct [:id, :title, :version, :entry, :permissions, :metadata, :chrome]

  @spec normalize(map()) :: {:ok, t()} | {:error, String.t()}
  def normalize(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, id} <- normalize_id(Map.get(attrs, "id")),
         {:ok, title} <- normalize_title(Map.get(attrs, "title")),
         {:ok, version} <- normalize_version(Map.get(attrs, "version", "0.1.0")),
         {:ok, entry} <- normalize_entry(Map.get(attrs, "entry", "index.html")),
         {:ok, permissions} <- normalize_permissions(Map.get(attrs, "permissions", [])),
         {:ok, metadata} <- normalize_metadata(Map.get(attrs, "metadata", %{})),
         {:ok, chrome} <- normalize_chrome(Map.get(attrs, "chrome", %{})) do
      {:ok,
       %__MODULE__{
         id: id,
         title: title,
         version: version,
         entry: entry,
         permissions: permissions,
         metadata: metadata,
         chrome: chrome
       }}
    end
  end

  def normalize(_), do: {:error, "manifest must be a JSON object"}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = manifest) do
    %{
      "id" => manifest.id,
      "title" => manifest.title,
      "version" => manifest.version,
      "entry" => manifest.entry,
      "permissions" => manifest.permissions,
      "metadata" => manifest.metadata,
      "chrome" => manifest.chrome
    }
  end

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(@id_regex, id)
  def valid_id?(_), do: false

  defp normalize_id(id) when is_binary(id) do
    id = String.trim(id)

    if valid_id?(id) do
      {:ok, id}
    else
      {:error, "id must match ^[a-z][a-z0-9_-]{1,63}$"}
    end
  end

  defp normalize_id(_), do: {:error, "id is required"}

  defp normalize_title(title) when is_binary(title) do
    title = String.trim(title)

    cond do
      title == "" -> {:error, "title is required"}
      String.length(title) > 120 -> {:error, "title must be at most 120 characters"}
      contains_control?(title) -> {:error, "title must not contain control characters"}
      true -> {:ok, title}
    end
  end

  defp normalize_title(_), do: {:error, "title is required"}

  defp normalize_version(version) when is_binary(version) do
    version = String.trim(version)

    cond do
      version == "" -> {:error, "version is required"}
      String.length(version) > 64 -> {:error, "version must be at most 64 characters"}
      contains_control?(version) -> {:error, "version must not contain control characters"}
      true -> {:ok, version}
    end
  end

  defp normalize_version(_), do: {:error, "version must be a string"}

  defp normalize_entry(entry) when is_binary(entry) do
    entry = String.trim(entry)
    segments = Path.split(entry)

    cond do
      entry == "" -> {:error, "entry is required"}
      contains_control?(entry) -> {:error, "entry must not contain control characters"}
      Path.type(entry) != :relative -> {:error, "entry must be a relative path"}
      Enum.any?(segments, &(&1 == "..")) -> {:error, "entry must not contain .. segments"}
      true -> {:ok, entry}
    end
  end

  defp normalize_entry(_), do: {:error, "entry is required"}

  defp normalize_permissions(permissions) when is_list(permissions) do
    permissions
    |> Enum.reduce_while({:ok, []}, fn permission, {:ok, acc} ->
      case normalize_permission(permission) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_permissions(_), do: {:error, "permissions must be a list"}

  @spec normalize_permission(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_permission(permission) when is_binary(permission) do
    permission = String.trim(permission)

    cond do
      permission == "" ->
        {:error, "permission must not be empty"}

      String.length(permission) > @max_permission_length ->
        {:error, "permission must be at most #{@max_permission_length} characters"}

      contains_control?(permission) ->
        {:error, "permission must not contain control characters"}

      true ->
        {:ok, permission}
    end
  end

  def normalize_permission(_), do: {:error, "permission must be a string"}

  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, stringify_keys(metadata)}
  defp normalize_metadata(_), do: {:error, "metadata must be an object"}

  defp normalize_chrome(chrome) when is_map(chrome) do
    chrome = stringify_keys(chrome)

    with {:ok, topbar} <- normalize_topbar(Map.get(chrome, "topbar", "auto")) do
      {:ok, %{"topbar" => topbar}}
    end
  end

  defp normalize_chrome(_), do: {:error, "chrome must be an object"}

  defp normalize_topbar(topbar) when is_binary(topbar) do
    topbar = topbar |> String.trim() |> String.downcase()

    if topbar in ["auto", "hidden"] do
      {:ok, topbar}
    else
      {:error, "chrome.topbar must be auto or hidden"}
    end
  end

  defp normalize_topbar(_), do: {:error, "chrome.topbar must be a string"}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} when is_binary(key) -> {key, stringify_value(value)}
      {key, value} -> {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(value), do: value

  defp contains_control?(value) when is_binary(value),
    do: String.match?(value, ~r/[\x00-\x1F\x7F]/)
end
