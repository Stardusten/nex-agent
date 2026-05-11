defmodule Nex.Agent.Channel.Feishu.CardBuilder do
  @moduledoc false

  alias Nex.Agent.Interface.IMIR.Renderers.Feishu, as: FeishuRenderer
  alias Nex.Agent.Interface.Outbound.Approval, as: OutboundApproval

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

    metadata = Keyword.get(opts, :metadata, %{})
    approval_card? = OutboundApproval.approval_request?(metadata)

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
      |> maybe_append_approval_actions(metadata, opts)

    streaming_mode = Keyword.get(opts, :streaming_mode)

    config =
      %{
        "width_mode" => "fill",
        "summary" => %{"content" => summary}
      }
      |> maybe_put("update_multi", Keyword.get(opts, :update_multi?, approval_card?))
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

  defp maybe_append_approval_actions(elements, metadata, opts) when is_map(metadata) do
    if OutboundApproval.buttons_allowed?(metadata) do
      append_approval_actions(elements, metadata, opts)
    else
      elements
    end
  end

  defp maybe_append_approval_actions(elements, _metadata, _opts), do: elements

  defp append_approval_actions(elements, metadata, opts) do
    case OutboundApproval.request(metadata) do
      %{} = request ->
        request_id = Map.get(request, "request_id")

        buttons =
          request
          |> Map.get("actions", [])
          |> Enum.filter(&is_map/1)
          |> Enum.map(&approval_button(request_id, &1, metadata, opts))
          |> Enum.reject(&is_nil/1)

        if buttons == [] do
          elements
        else
          elements ++ buttons
        end

      _ ->
        elements
    end
  end

  defp approval_button(request_id, %{} = action, metadata, opts) do
    action_id = Map.get(action, "id")
    label = Map.get(action, "label")

    if is_binary(request_id) and is_binary(action_id) and is_binary(label) do
      %{
        "tag" => "button",
        "element_id" => approval_button_element_id(action_id),
        "text" => %{"tag" => "plain_text", "content" => label},
        "type" => feishu_button_type(Map.get(action, "style")),
        "behaviors" => [
          %{
            "type" => "callback",
            "value" =>
              %{
                "nex_action" => "approval",
                "request_id" => request_id,
                "action_id" => action_id,
                "custom_id" => OutboundApproval.custom_id(request_id, action_id),
                "command" => Map.get(action, "command")
              }
              |> maybe_put("channel", Map.get(metadata, "channel"))
              |> maybe_put("chat_id", Keyword.get(opts, :chat_id) || Map.get(metadata, "chat_id"))
          }
        ]
      }
    end
  end

  defp approval_button_element_id(action_id) do
    action_id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_]/, "_")
    |> then(&"btn_#{&1}")
    |> String.slice(0, 20)
  end

  defp feishu_button_type("primary"), do: "primary"
  defp feishu_button_type("success"), do: "primary"
  defp feishu_button_type("danger"), do: "danger"
  defp feishu_button_type(_style), do: "default"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
