defmodule Nex.Agent.Tool.ImageGeneration do
  @moduledoc """
  Image generation capability with pluggable local backends.
  """

  @behaviour Nex.Agent.Tool.Behaviour

  alias Nex.Agent.Config
  alias Nex.Agent.Tool.Backends.OpenAICodex

  def name, do: "image_generation"
  def description, do: "Generate or edit images from text and image context."
  def category, do: :base

  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          prompt: %{
            type: "string",
            description: "Image generation or editing instruction"
          }
        },
        required: ["prompt"]
      }
    }
  end

  def execute(%{"prompt" => prompt}, ctx) when is_binary(prompt) and prompt != "" do
    provider_config = provider_config(ctx)
    provider = Map.get(provider_config, "provider", "codex")
    selected_config = selected_provider_config(provider_config)

    case provider do
      "codex" ->
        OpenAICodex.image_generation(prompt, normalize_ctx(ctx), selected_config)

      "nanobanana" ->
        {:error,
         "image_generation provider \"nanobanana\" is not implemented yet. [Analyze the error and try a different approach.]"}

      _ ->
        {:error,
         "image_generation provider #{inspect(provider)} is not supported. [Analyze the error and try a different approach.]"}
    end
  end

  def execute(_args, _ctx),
    do: {:error, "image_generation requires a non-empty prompt. [Analyze the error and try a different approach.]"}

  defp provider_config(ctx) when is_map(ctx) do
    case Map.get(ctx, :config) || Map.get(ctx, "config") do
      %Config{} = config -> Config.image_generation_provider_config(config)
      _ -> Config.image_generation_provider_config(nil)
    end
  end

  defp provider_config(_ctx), do: Config.image_generation_provider_config(nil)

  defp selected_provider_config(provider_config) do
    provider = Map.get(provider_config, "provider", "codex")
    providers = Map.get(provider_config, "providers", %{})
    Map.get(providers, provider, %{})
  end

  defp normalize_ctx(ctx) when is_map(ctx), do: ctx
  defp normalize_ctx(_ctx), do: %{}
end
