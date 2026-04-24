defmodule Nex.Agent.Tool.CapabilityAdapter do
  @moduledoc false

  alias Nex.Agent.LLM.ProviderProfile
  alias Nex.Agent.Tool.Capability

  @callback resolve(module(), ProviderProfile.t(), map()) :: Capability.t()
end
