defmodule Nex.Agent.Tool.Capabilities.ImageGeneration.OpenAICodexAdapter do
  @moduledoc false

  @behaviour Nex.Agent.Tool.CapabilityAdapter

  alias Nex.Agent.Tool.Capability

  @impl true
  def resolve(module, _profile, _capability_config) do
    %Capability{
      tool_name: "image_generation",
      strategy: :local,
      definition: module.definition(),
      provider_native: nil
    }
  end
end
