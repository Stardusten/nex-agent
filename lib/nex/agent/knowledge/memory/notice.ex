defmodule Nex.Agent.Knowledge.Memory.Notice do
  @moduledoc false

  alias Nex.Agent.{App.Bus, Interface.Outbound}
  alias Nex.Agent.Observe.ControlPlane.Log
  require Log

  @prefix "🧠 Memory - "
  @summary_max_chars 140
  @truncation_suffix "..."

  @spec maybe_send(map(), keyword()) :: {:sent, :ok} | {:skipped, String.t()}
  def maybe_send(%{status: :updated} = result, opts) do
    notify? = Keyword.get(opts, :notify, false) == true
    channel = Keyword.get(opts, :channel)
    chat_id = Keyword.get(opts, :chat_id)
    workspace = Keyword.get(opts, :workspace)
    session_key = Keyword.get(opts, :session_key)

    cond do
      not notify? ->
        skip("notify_disabled", result, opts)

      not present?(channel) or not present?(chat_id) ->
        skip("missing_outbound_target", result, opts)

      Process.whereis(Bus) == nil ->
        skip("bus_not_running", result, opts)

      true ->
        content = render(Map.get(result, :summary))
        topic = Outbound.topic_for_channel(channel)

        Bus.publish(topic, %{
          chat_id: chat_id,
          content: content,
          metadata: %{
            "_memory_notice" => true,
            "channel" => channel,
            "chat_id" => chat_id,
            "session_key" => session_key,
            "source" => Keyword.get(opts, :source, "memory_refresh")
          }
        })

        Log.info(
          "memory.notice.sent",
          notice_attrs(result, %{
            "channel" => to_string(channel),
            "chat_id" => to_string(chat_id),
            "source" => Keyword.get(opts, :source, "memory_refresh")
          }),
          workspace: workspace,
          session_key: session_key
        )

        {:sent, :ok}
    end
  end

  def maybe_send(%{} = result, opts), do: skip("not_updated", result, opts)
  def maybe_send(_result, opts), do: skip("invalid_result", %{}, opts)

  @spec render(String.t() | nil) :: String.t()
  def render(summary), do: @prefix <> summary(summary)

  @spec summary(String.t() | nil) :: String.t()
  def summary(nil), do: "Memory updated."

  def summary(value) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> "Memory updated."
      summary -> truncate_summary(summary)
    end
  end

  defp skip(reason, result, opts) do
    workspace = Keyword.get(opts, :workspace)
    session_key = Keyword.get(opts, :session_key)

    Log.info(
      "memory.notice.skipped",
      notice_attrs(result, %{
        "reason" => reason,
        "source" => Keyword.get(opts, :source, "memory_refresh")
      }),
      workspace: workspace,
      session_key: session_key
    )

    {:skipped, reason}
  end

  defp notice_attrs(result, extra) do
    %{
      "status" => result |> Map.get(:status) |> to_string(),
      "summary" => notice_summary(Map.get(result, :summary)),
      "before_hash" => Map.get(result, :before_hash),
      "after_hash" => Map.get(result, :after_hash),
      "memory_bytes" => Map.get(result, :memory_bytes),
      "model_role" => Map.get(result, :model_role),
      "provider" => Map.get(result, :provider),
      "model" => Map.get(result, :model)
    }
    |> Map.merge(extra)
  end

  defp notice_summary(nil), do: nil
  defp notice_summary(summary), do: summary(summary)

  defp truncate_summary(summary) do
    if String.length(summary) > @summary_max_chars do
      summary
      |> String.slice(0, @summary_max_chars - String.length(@truncation_suffix))
      |> String.trim_trailing()
      |> Kernel.<>(@truncation_suffix)
    else
      summary
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
