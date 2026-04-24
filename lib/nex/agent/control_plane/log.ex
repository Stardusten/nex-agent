defmodule Nex.Agent.ControlPlane.Log do
  @moduledoc false

  require Logger

  alias Nex.Agent.ControlPlane.Store

  for level <- [:debug, :info, :warning, :error] do
    defmacro unquote(level)(tag, attrs, opts \\ []) do
      source = __CALLER__ |> caller_source() |> Macro.escape()
      level_string = unquote(Atom.to_string(level))

      quote bind_quoted: [tag: tag, attrs: attrs, opts: opts, source: source, level: level_string] do
        Nex.Agent.ControlPlane.Log.emit(level, tag, attrs, opts, source)
      end
    end
  end

  @spec emit(String.t(), String.t(), map(), keyword(), map()) :: {:ok, map()} | {:error, term()}
  def emit(level, tag, attrs, opts, source)
      when is_binary(level) and is_binary(tag) and is_map(attrs) and is_list(opts) do
    result =
      Store.append(
        %{
          "kind" => "log",
          "level" => level,
          "tag" => tag,
          "source" => source,
          "context" => Keyword.get(opts, :context, %{}),
          "attrs" => attrs
        },
        opts
      )

    project(level, tag, result)
    result
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

  defp project(level, tag, {:ok, observation}) do
    message = "[#{tag}] #{inspect(Map.get(observation, "attrs", %{}))}"

    case level do
      "debug" -> Logger.debug(message)
      "info" -> Logger.info(message)
      "warning" -> Logger.warning(message)
      "error" -> Logger.error(message)
      _ -> Logger.info(message)
    end
  end

  defp project(_level, tag, {:error, reason}) do
    Logger.warning("[control_plane.log.failed] tag=#{tag} reason=#{inspect(reason)}")
  end
end
