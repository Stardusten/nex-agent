defmodule Nex.Agent.Observe.ControlPlane.Gauge do
  @moduledoc false

  alias Nex.Agent.Observe.ControlPlane.Redactor
  alias Nex.Agent.Observe.ControlPlane.Store

  defmacro set(name, value, attrs, opts \\ []) do
    source = __CALLER__ |> caller_source() |> Macro.escape()

    quote bind_quoted: [name: name, value: value, attrs: attrs, opts: opts, source: source] do
      Nex.Agent.Observe.ControlPlane.Gauge.set_value(name, value, attrs, opts, source)
    end
  end

  @spec set_value(String.t(), term(), map(), keyword(), map()) :: {:ok, map()} | {:error, term()}
  def set_value(name, value, attrs, opts, source)
      when is_binary(name) and is_map(attrs) and is_list(opts) do
    normalized =
      Store.normalize_observation(
        %{
          "kind" => "gauge",
          "level" => "info",
          "tag" => name,
          "source" => source,
          "attrs" => attrs
        },
        opts
      )

    record =
      %{
        "name" => name,
        "value" => value,
        "updated_at" => Store.timestamp(),
        "context" => normalized["context"],
        "attrs" => normalized["attrs"]
      }
      |> Redactor.redact()

    with :ok <- persist(record, opts),
         {:ok, observation} <-
           Store.append(
             %{
               "kind" => "gauge",
               "level" => "info",
               "tag" => name,
               "source" => source,
               "context" => record["context"],
               "attrs" => Map.put(record["attrs"], "value", record["value"])
             },
             opts
           ) do
      {:ok, observation}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec current(String.t(), keyword()) :: map() | nil
  def current(name, opts \\ []) when is_binary(name) do
    opts
    |> all()
    |> Map.get(name)
  end

  @spec all(keyword()) :: map()
  def all(opts \\ []) do
    path = Store.gauges_path(opts)

    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = gauges} -> gauges
          _ -> %{}
        end

      {:error, _reason} ->
        %{}
    end
  rescue
    _e -> %{}
  end

  defp persist(record, opts) do
    path = Store.gauges_path(opts)
    gauges = Map.put(all(opts), record["name"], record)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode!(gauges))
    end
  end

  defp caller_source(env) do
    function =
      case env.function do
        {name, arity} -> "#{name}/#{arity}"
        nil -> nil
      end

    %{
      "module" => inspect(env.module),
      "function" => function,
      "file" => env.file,
      "line" => env.line
    }
  end
end
