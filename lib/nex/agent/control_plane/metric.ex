defmodule Nex.Agent.ControlPlane.Metric do
  @moduledoc false

  alias Nex.Agent.ControlPlane.Store

  defmacro count(name, value, attrs, opts \\ []) do
    source = __CALLER__ |> caller_source() |> Macro.escape()

    quote bind_quoted: [name: name, value: value, attrs: attrs, opts: opts, source: source] do
      Nex.Agent.ControlPlane.Metric.emit("count", name, value, attrs, opts, source)
    end
  end

  defmacro measure(name, value, attrs, opts \\ []) do
    source = __CALLER__ |> caller_source() |> Macro.escape()

    quote bind_quoted: [name: name, value: value, attrs: attrs, opts: opts, source: source] do
      Nex.Agent.ControlPlane.Metric.emit("measure", name, value, attrs, opts, source)
    end
  end

  @spec emit(String.t(), String.t(), number(), map(), keyword(), map()) ::
          {:ok, map()} | {:error, term()}
  def emit(type, name, value, attrs, opts, source)
      when is_binary(type) and is_binary(name) and is_map(attrs) and is_list(opts) do
    attrs =
      attrs
      |> Store.stringify_keys()
      |> Map.put("metric_type", type)
      |> Map.put("value", value)

    Store.append(
      %{
        "kind" => "metric",
        "level" => "info",
        "tag" => name,
        "source" => source,
        "context" => Keyword.get(opts, :context, %{}),
        "attrs" => attrs
      },
      opts
    )
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
