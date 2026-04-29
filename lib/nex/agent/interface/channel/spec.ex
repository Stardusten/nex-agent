defmodule Nex.Agent.Interface.Channel.Spec do
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
  @callback start_stream(String.t(), String.t(), map(), keyword()) ::
              {:ok, term()} | :ignore | {:error, term()}
  @callback handle_stream_event(term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback handle_stream_timer(term(), atom(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback finalize_stream(term(), term(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  @callback cancel_stream(term()) :: :ok | term()
  @callback start_follow_up_typing(String.t(), String.t(), keyword()) :: reference() | nil
  @callback handle_follow_up_typing(String.t(), String.t(), keyword()) :: reference() | nil

  @optional_callbacks start_stream: 4,
                      handle_stream_event: 3,
                      handle_stream_timer: 3,
                      finalize_stream: 3,
                      cancel_stream: 1,
                      start_follow_up_typing: 3,
                      handle_follow_up_typing: 3
end
