defmodule Nex.Agent.Tool.CapabilityResolverTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Config
  alias Nex.Agent.Tool.{Capability, CapabilityResolver, ImageGeneration, WebSearch}

  test "web_search resolves to local tool definition even on official openai_codex backend" do
    config =
      %Config{
        Config.default()
        | provider: "openai-codex",
          tools: %{
            "web_search" => %{
              "strategy" => "auto",
              "backend" => "auto",
              "mode" => "cached",
              "allowed_domains" => ["example.com", "example.com"],
              "user_location" => %{"country" => "US", "city" => "San Francisco"}
            }
          }
      }

    capability =
      CapabilityResolver.resolve(WebSearch,
        config: config,
        provider: :openai_codex,
        base_url: "https://chatgpt.com/backend-api/codex"
      )

    assert Capability.to_contract_map(capability) == %{
             "tool_name" => "web_search",
             "strategy" => "local",
             "definition" => WebSearch.definition(),
             "provider_native" => nil
           }
  end

  test "web_search with explicit openai_codex backend still resolves as local tool contract" do
    config =
      %Config{
        Config.default()
        | provider: "openai-codex",
          tools: %{
            "web_search" => %{"strategy" => "provider_native", "mode" => "live", "backend" => "openai_codex"}
          }
      }

    capability =
      CapabilityResolver.resolve(WebSearch,
        config: config,
        provider: :openai_codex,
        base_url: "https://proxy.example.com/codex"
      )

    assert capability.strategy == :local
    assert capability.definition == WebSearch.definition()
    assert capability.provider_native == nil
  end

  test "web_search auto falls back to local on unsupported backend" do
    config =
      %Config{
        Config.default()
        | provider: "openai-codex",
          tools: %{
            "web_search" => %{"strategy" => "auto", "mode" => "live"}
            |> Map.put("backend", "auto")
          }
      }

    capability =
      CapabilityResolver.resolve(WebSearch,
        config: config,
        provider: :openai_codex,
        base_url: "https://proxy.example.com/codex"
      )

    assert capability.strategy == :local
    assert get_in(capability.definition, [:name]) == "web_search"
    assert capability.provider_native == nil
  end

  test "web_search disabled mode removes both local and native definitions" do
    config =
      %Config{
        Config.default()
        | tools: %{
            "web_search" => %{"strategy" => "auto", "mode" => "disabled"}
            |> Map.put("backend", "auto")
          }
      }

    capability =
      CapabilityResolver.resolve(WebSearch,
        config: config,
        provider: :openai_codex,
        base_url: "https://chatgpt.com/backend-api/codex"
      )

    assert Capability.to_contract_map(capability) == %{
             "tool_name" => "web_search",
             "strategy" => "disabled",
             "definition" => nil,
             "provider_native" => nil
           }
  end

  test "image_generation resolves to local tool definition on official openai_codex backend" do
    config =
      %Config{
        Config.default()
        | provider: "openai-codex",
          tools: %{
            "image_generation" => %{
              "strategy" => "auto",
              "backend" => "auto",
              "output_format" => "webp"
            }
          }
      }

    capability =
      CapabilityResolver.resolve(ImageGeneration,
        config: config,
        provider: :openai_codex,
        base_url: "https://chatgpt.com/backend-api/codex"
      )

    assert Capability.to_contract_map(capability) == %{
             "tool_name" => "image_generation",
             "strategy" => "local",
             "definition" => ImageGeneration.definition(),
             "provider_native" => nil
           }
  end

  test "image_generation with explicit codex backend still resolves as local tool contract" do
    config =
      %Config{
        Config.default()
        | provider: "openai-codex",
          tools: %{
            "image_generation" => %{"strategy" => "provider_native", "backend" => "openai_codex"}
          }
      }

    capability =
      CapabilityResolver.resolve(ImageGeneration,
        config: config,
        provider: :anthropic
      )

    assert Capability.to_contract_map(capability) == %{
             "tool_name" => "image_generation",
             "strategy" => "local",
             "definition" => ImageGeneration.definition(),
             "provider_native" => nil
           }
  end
end
