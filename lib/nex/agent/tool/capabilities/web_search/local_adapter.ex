defmodule Nex.Agent.Tool.Capabilities.WebSearch.LocalAdapter do
  @moduledoc false

  @behaviour Nex.Agent.Tool.CapabilityAdapter

  alias Nex.Agent.Tool.Capability

  @impl true
  def resolve(module, _profile, _config) do
    %Capability{
      tool_name: "web_search",
      strategy: :local,
      definition: module.definition(),
      provider_native: nil
    }
  end
end
