defmodule Nex.Agent.Turn.LLM.ProviderAdapter do
  @moduledoc false

  alias Nex.Agent.Turn.LLM.ProviderProfile

  @type stream_text_fun ::
          (ReqLLM.model_input(), ReqLLM.Context.prompt(), keyword() ->
             {:ok, ReqLLM.StreamResponse.t()} | {:error, term()})

  @callback build_profile(keyword()) :: ProviderProfile.t()
  @callback default_model() :: String.t()
  @callback default_api_key() :: String.t() | nil
  @callback default_base_url() :: String.t() | nil
  @callback prepare_messages_and_options([map()], ProviderProfile.t(), keyword()) ::
              {[map()], keyword()}
  @callback api_key_config(ProviderProfile.t(), keyword()) :: {String.t() | nil, boolean()}
  @callback provider_options(ProviderProfile.t(), keyword()) :: keyword()
  @callback model_spec(ProviderProfile.t(), String.t()) :: String.t() | map()
  @callback stream_text_fun(ProviderProfile.t()) :: stream_text_fun()
  @callback forced_tool_choice(ProviderProfile.t(), String.t()) :: map() | nil

  @optional_callbacks default_model: 0,
                      default_api_key: 0,
                      default_base_url: 0,
                      prepare_messages_and_options: 3,
                      api_key_config: 2,
                      provider_options: 2,
                      model_spec: 2,
                      stream_text_fun: 1,
                      forced_tool_choice: 2
end
