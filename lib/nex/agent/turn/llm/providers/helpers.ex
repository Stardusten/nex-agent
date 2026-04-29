defmodule Nex.Agent.Turn.LLM.Providers.Helpers do
  @moduledoc false

  @fallback_instructions "You are a helpful coding assistant."

  @spec present?(term()) :: boolean()
  def present?(value) when value in [nil, "", []], do: false
  def present?(_), do: true

  @spec trim_base_url(String.t() | nil) :: String.t() | nil
  def trim_base_url(nil), do: nil
  def trim_base_url(base_url) when is_binary(base_url), do: String.trim_trailing(base_url, "/")

  @spec deepseek_base_url?(term()) :: boolean()
  def deepseek_base_url?(base_url) when is_binary(base_url) do
    host =
      case URI.parse(base_url) do
        %URI{host: host} when is_binary(host) -> host
        _ -> base_url
      end

    host
    |> String.downcase()
    |> String.contains?("deepseek")
  end

  def deepseek_base_url?(_base_url), do: false

  @spec map_model_spec(Nex.Agent.Turn.LLM.ProviderProfile.t(), String.t()) :: map()
  def map_model_spec(profile, model) do
    %{id: model, provider: profile.resolved_provider, base_url: profile.base_url}
  end

  @spec default_model_spec(Nex.Agent.Turn.LLM.ProviderProfile.t(), String.t()) ::
          String.t() | map()
  def default_model_spec(profile, model) do
    if present?(profile.base_url) do
      map_model_spec(profile, model)
    else
      "#{profile.resolved_provider}:#{model}"
    end
  end

  @spec extract_system_instructions([map()]) :: {String.t(), [map()]}
  def extract_system_instructions(messages) do
    {system_messages, other_messages} =
      Enum.split_with(messages, fn message -> message["role"] == "system" end)

    instructions =
      system_messages
      |> Enum.map(&message_content_to_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> case do
        "" -> @fallback_instructions
        text -> text
      end

    {instructions, other_messages}
  end

  defp message_content_to_text(%{"content" => content}), do: content_to_text(content)
  defp message_content_to_text(_), do: ""

  defp content_to_text(content) when is_binary(content), do: String.trim(content)

  defp content_to_text(content) when is_list(content) do
    content
    |> Enum.map(&content_part_to_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp content_to_text(_), do: ""

  defp content_part_to_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp content_part_to_text(%{type: "text", text: text}) when is_binary(text), do: text
  defp content_part_to_text(%{"text" => text}) when is_binary(text), do: text
  defp content_part_to_text(%{text: text}) when is_binary(text), do: text
  defp content_part_to_text(part) when is_binary(part), do: part
  defp content_part_to_text(_), do: ""
end
