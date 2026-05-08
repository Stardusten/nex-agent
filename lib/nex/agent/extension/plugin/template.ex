defmodule Nex.Agent.Extension.Plugin.Template do
  @moduledoc """
  Template resolver for plugin contribution attrs.

  The resolver returns both the execution value and a redacted projection so
  callers do not have to guess which paths carried secret material.
  """

  alias Nex.Agent.SecretBase

  defmodule Result do
    @moduledoc false
    defstruct value: nil, redacted_value: nil, redactions: []
  end

  @type result :: %Result{value: term(), redacted_value: term(), redactions: [map()]}
  @type render_error :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          optional(:path) => String.t(),
          optional(:secret_id) => String.t(),
          optional(:reason) => term(),
          optional(:redacted_value) => term()
        }

  @placeholder_re ~r/\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}/
  @max_nested_depth 8

  @spec render(term(), map()) :: term()
  def render(value, ctx) do
    case render_result(value, ctx) do
      {:ok, %Result{value: rendered}} -> rendered
      {:error, _reason} -> value
    end
  end

  @spec render_result(term(), map()) :: {:ok, result()} | {:error, render_error()}
  def render_result(value, ctx) when is_map(ctx) do
    render_value(value, ctx, @max_nested_depth)
  end

  def render_result(value, _ctx), do: {:ok, result(value, value, [])}

  @spec redacted_value(result() | term()) :: term()
  def redacted_value(%Result{redacted_value: redacted}), do: redacted
  def redacted_value(value), do: value

  @spec redacted_error(render_error() | term()) :: term()
  def redacted_error(%{} = error),
    do: Map.take(error, [:code, :message, :path, :secret_id, :reason])

  def redacted_error(error), do: error

  defp render_value(value, ctx, depth) when is_map(value) do
    value
    |> Enum.reduce_while({%{}, %{}, []}, fn {key, nested}, {values, redacted, redactions} ->
      case render_value(nested, ctx, depth) do
        {:ok, %Result{} = result} ->
          {:cont,
           {
             Map.put(values, key, result.value),
             Map.put(redacted, key, result.redacted_value),
             redactions ++ result.redactions
           }}

        {:error, error} ->
          {:halt, {:error, Map.put_new(error, :redacted_value, redacted)}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      {values, redacted, redactions} -> {:ok, result(values, redacted, redactions)}
    end
  end

  defp render_value(value, ctx, depth) when is_list(value) do
    value
    |> Enum.reduce_while({[], [], []}, fn nested, {values, redacted, redactions} ->
      case render_value(nested, ctx, depth) do
        {:ok, %Result{} = result} ->
          {:cont,
           {[result.value | values], [result.redacted_value | redacted],
            redactions ++ result.redactions}}

        {:error, error} ->
          {:halt, {:error, Map.put_new(error, :redacted_value, Enum.reverse(redacted))}}
      end
    end)
    |> case do
      {:error, error} ->
        {:error, error}

      {values, redacted, redactions} ->
        {:ok, result(Enum.reverse(values), Enum.reverse(redacted), redactions)}
    end
  end

  defp render_value(value, ctx, depth) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> render_value(ctx, depth)
    |> case do
      {:ok, %Result{} = result} ->
        {:ok,
         %Result{
           result
           | value: List.to_tuple(result.value),
             redacted_value: List.to_tuple(result.redacted_value)
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp render_value(value, ctx, depth) when is_binary(value) do
    render_string(value, ctx, depth)
  end

  defp render_value(value, _ctx, _depth), do: {:ok, result(value, value, [])}

  defp render_string(value, _ctx, depth) when depth <= 0,
    do: {:ok, result(value, value, [])}

  defp render_string(value, ctx, depth) do
    @placeholder_re
    |> Regex.scan(value)
    |> Enum.reduce_while({value, value, []}, fn [placeholder, path],
                                                {rendered, redacted, redactions} ->
      case resolve_placeholder(path, ctx, depth - 1) do
        {:ok, replacement, redacted_replacement, nested_redactions} ->
          {:cont,
           {
             String.replace(rendered, placeholder, replacement),
             String.replace(redacted, placeholder, redacted_replacement),
             redactions ++ nested_redactions
           }}

        {:error, error} ->
          {:halt, {:error, Map.put_new(error, :redacted_value, redacted)}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      {rendered, redacted, redactions} -> {:ok, result(rendered, redacted, redactions)}
    end
  end

  defp resolve_placeholder("secret." <> secret_id = path, ctx, _depth) do
    case SecretBase.resolve(secret_id, ctx) do
      {:ok, value} ->
        redaction = %{path: path, secret_id: secret_id, replacement: "[REDACTED]"}
        {:ok, value, "[REDACTED]", [redaction]}

      {:error, reason} ->
        {:error,
         %{
           code: :missing_secret,
           message: "missing secret #{secret_id}",
           path: path,
           secret_id: secret_id,
           reason: reason
         }}
    end
  end

  defp resolve_placeholder(path, ctx, depth) do
    value =
      path
      |> String.split(".")
      |> resolve_path(ctx)

    render_resolved_value(value, ctx, depth)
  end

  defp render_resolved_value(nil, _ctx, _depth), do: {:ok, "", "", []}

  defp render_resolved_value(value, ctx, depth) when is_binary(value) do
    case render_string(value, ctx, depth) do
      {:ok, %Result{} = result} -> {:ok, result.value, result.redacted_value, result.redactions}
      {:error, error} -> {:error, error}
    end
  end

  defp render_resolved_value(value, _ctx, _depth) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value), Atom.to_string(value), []}

  defp render_resolved_value(value, _ctx, _depth)
       when is_integer(value) or is_float(value) or is_boolean(value),
       do: {:ok, to_string(value), to_string(value), []}

  defp render_resolved_value(value, _ctx, _depth), do: {:ok, inspect(value), inspect(value), []}

  defp resolve_path(["plugin", "id"], ctx),
    do: get_ctx(ctx, :plugin_id) || get_in_ctx(ctx, [:plugin, :id])

  defp resolve_path(["plugin", "config" | rest], ctx) do
    plugin_config(ctx)
    |> get_path(rest)
  end

  defp resolve_path(["workspace", "root"], ctx) do
    get_ctx(ctx, :workspace_root) || get_in_ctx(ctx, [:workspace, :root]) ||
      get_ctx(ctx, :workspace)
  end

  defp resolve_path(["workspace", "hash"], ctx) do
    ["workspace", "root"]
    |> resolve_path(ctx)
    |> workspace_hash()
  end

  defp resolve_path(["session", "key"], ctx),
    do: get_ctx(ctx, :session_key) || get_in_ctx(ctx, [:session, :key])

  defp resolve_path(["turn", "prompt"], ctx),
    do: get_ctx(ctx, :turn_prompt) || get_in_ctx(ctx, [:turn, :prompt])

  defp resolve_path(["channel"], ctx), do: get_ctx(ctx, :channel)
  defp resolve_path(["chat_id"], ctx), do: get_ctx(ctx, :chat_id)
  defp resolve_path(path, ctx), do: get_path(ctx, path)

  defp plugin_config(ctx) do
    get_ctx(ctx, :plugin_config) ||
      case {get_ctx(ctx, :config), get_ctx(ctx, :plugin_id)} do
        {%Nex.Agent.Runtime.Config{} = config, plugin_id} when is_binary(plugin_id) ->
          config |> Nex.Agent.Runtime.Config.plugins_runtime() |> get_in(["config", plugin_id])

        {%{} = config, plugin_id} when is_binary(plugin_id) ->
          config |> get_in_ctx([:plugins, :config, plugin_id])

        _ ->
          nil
      end ||
      %{}
  end

  defp workspace_hash(nil), do: ""

  defp workspace_hash(root) do
    :crypto.hash(:sha256, to_string(root))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp get_ctx(ctx, key), do: get_key(ctx, key)
  defp get_in_ctx(value, path), do: get_path(value, path)

  defp get_path(value, path) do
    Enum.reduce_while(path, value, fn key, acc ->
      case get_key(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp get_key(%{} = map, key) when is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp get_key(%{} = map, key) when is_binary(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      true -> get_existing_atom_key(map, key)
    end
  end

  defp get_key(_value, _key), do: nil

  defp get_existing_atom_key(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp result(value, redacted_value, redactions) do
    %Result{value: value, redacted_value: redacted_value, redactions: redactions}
  end
end
