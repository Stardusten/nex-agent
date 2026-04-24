defmodule Nex.Agent.Tool.Capability do
  @moduledoc false

  @enforce_keys [:tool_name, :strategy]
  defstruct tool_name: nil,
            strategy: :local,
            definition: nil,
            provider_native: nil

  @type strategy :: :local | :provider_native | :disabled

  @type t :: %__MODULE__{
          tool_name: String.t(),
          strategy: strategy(),
          definition: map() | nil,
          provider_native: map() | nil
        }

  @spec execution_strategy(t()) :: strategy()
  def execution_strategy(%__MODULE__{strategy: strategy}), do: strategy

  @spec llm_definition(t()) :: map() | nil
  def llm_definition(%__MODULE__{strategy: :provider_native, provider_native: definition})
      when is_map(definition),
      do: definition

  def llm_definition(%__MODULE__{definition: definition}) when is_map(definition), do: definition
  def llm_definition(%__MODULE__{}), do: nil

  @spec to_contract_map(t()) :: map()
  def to_contract_map(%__MODULE__{} = capability) do
    %{
      "tool_name" => capability.tool_name,
      "strategy" => capability.strategy |> to_string(),
      "definition" => capability.definition,
      "provider_native" => capability.provider_native
    }
  end
end
