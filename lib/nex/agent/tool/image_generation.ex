defmodule Nex.Agent.Tool.ImageGeneration do
  @moduledoc """
  Image generation capability.

  Local execution is intentionally unsupported for now; capability resolution
  may expose a provider-native built-in tool on supported backends.
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
    capability = capability_config(ctx)

    case Map.get(capability, "backend", "auto") do
      "openai_codex" ->
        OpenAICodex.image_generation(prompt, normalize_ctx(ctx), capability)

      "auto" ->
        if codex_backend_supported?(ctx) do
          OpenAICodex.image_generation(prompt, normalize_ctx(ctx), capability)
        else
          {:error,
           "image_generation has no configured backend for the current provider/runtime. [Analyze the error and try a different approach.]"}
        end

      _ ->
        {:error,
         "image_generation has no configured backend for the current provider/runtime. [Analyze the error and try a different approach.]"}
    end
  end

  def execute(_args, _ctx),
    do: {:error, "image_generation requires a non-empty prompt. [Analyze the error and try a different approach.]"}

  defp capability_config(ctx) when is_map(ctx) do
    case Map.get(ctx, :config) || Map.get(ctx, "config") do
      %Config{} = config -> Config.image_generation_capability(config)
      _ -> Config.image_generation_capability(nil)
    end
  end

  defp capability_config(_ctx), do: Config.image_generation_capability(nil)

  defp codex_backend_supported?(ctx) when is_map(ctx) do
    configured_backend = Map.get(capability_config(ctx), "backend", "auto")
    provider = Map.get(ctx, :provider) || Map.get(ctx, "provider")
    base_url = Map.get(ctx, :base_url) || Map.get(ctx, "base_url")

    configured_backend == "openai_codex" or
      (configured_backend == "auto" and provider in [:openai_codex, "openai_codex"] and
         is_binary(base_url) and String.contains?(base_url, "chatgpt.com/backend-api/codex"))
  end

  defp codex_backend_supported?(_ctx), do: false

  defp normalize_ctx(ctx) when is_map(ctx), do: ctx
  defp normalize_ctx(_ctx), do: %{}
end
