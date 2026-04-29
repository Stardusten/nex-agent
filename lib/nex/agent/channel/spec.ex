defmodule Nex.Agent.Channel.Spec do
  @moduledoc """
  Behaviour for built-in channel type specifications.
  """

  @type instance_config :: map()
  @type runtime_config :: map()
  @type diagnostic :: %{
          optional(:code) => atom(),
          optional(:field) => String.t(),
          optional(:instance_id) => String.t(),
          optional(:type) => String.t() | nil,
          optional(:message) => String.t()
        }

  @callback type() :: String.t()
  @callback gateway_module() :: module()
  @callback apply_defaults(instance_config()) :: instance_config()
  @callback validate_instance(instance_config(), keyword()) :: :ok | {:error, [diagnostic()]}
  @callback runtime(instance_config()) :: runtime_config()
  @callback format_prompt(runtime_config(), keyword()) :: String.t()
  @callback im_profile() :: map() | nil
  @callback renderer() :: module() | nil
  @callback config_contract() :: map()
end
