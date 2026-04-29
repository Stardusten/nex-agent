defmodule Nex.Agent.Channel.Feishu.CardBuilder do
  @moduledoc false

  alias Nex.Agent.Interface.IMIR.Renderers.Feishu, as: FeishuRenderer

  @spec build(String.t(), keyword()) :: map()
  def build(text, opts \\ []) when is_binary(text) do
    summary =
      Keyword.get(opts, :summary) ||
        text
        |> String.trim()
        |> String.slice(0, 120)
        |> case do
          "" -> "NexAgent message"
          value -> value
        end

    elements =
      if Keyword.get(opts, :single_markdown?, false) do
        [
          %{
            "tag" => "markdown",
            "content" => text
          }
          |> maybe_put("element_id", Keyword.get(opts, :element_id))
        ]
      else
        FeishuRenderer.render_elements(text)
      end

    streaming_mode = Keyword.get(opts, :streaming_mode)

    config =
      %{
        "width_mode" => "fill",
        "summary" => %{"content" => summary}
      }
      |> maybe_put("streaming_mode", streaming_mode)
      |> maybe_put(
        "streaming_config",
        if(streaming_mode,
          do: %{
            "print_frequency_ms" => %{"default" => 50},
            "print_step" => %{"default" => 2},
            "print_strategy" => "fast"
          },
          else: nil
        )
      )

    %{
      "schema" => "2.0",
      "config" => config,
      "body" => %{
        "elements" => elements
      }
    }
  end

  @spec to_interactive_content(String.t(), keyword()) :: map()
  def to_interactive_content(text, opts \\ []) when is_binary(text) do
    build(text, opts)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
