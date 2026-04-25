defmodule Nex.Agent.Runtime.Snapshot do
  @moduledoc """
  Immutable runtime world view used by the agent main path.
  """

  alias Nex.Agent.Config

  @type t :: %__MODULE__{
          version: pos_integer(),
          config: Config.t(),
          workspace: String.t(),
          channels: %{optional(String.t()) => map()},
          commands: %{
            definitions: [map()],
            hash: String.t()
          },
          prompt: %{
            system_prompt: String.t(),
            diagnostics: [map()],
            hash: String.t()
          },
          tools: %{
            definitions_all: [map()],
            definitions_follow_up: [map()],
            definitions_subagent: [map()],
            definitions_cron: [map()],
            hash: String.t()
          },
          subagents: %{
            profiles: %{optional(String.t()) => Nex.Agent.Subagent.Profile.t()},
            definitions: [map()],
            hash: String.t()
          },
          skills: %{
            always_instructions: String.t(),
            hash: String.t()
          },
          changed_paths: [String.t()]
        }

  defstruct version: nil,
            config: nil,
            workspace: nil,
            channels: %{},
            commands: %{
              definitions: [],
              hash: ""
            },
            prompt: %{
              system_prompt: "",
              diagnostics: [],
              hash: ""
            },
            tools: %{
              definitions_all: [],
              definitions_follow_up: [],
              definitions_subagent: [],
              definitions_cron: [],
              hash: ""
            },
            subagents: %{
              profiles: %{},
              definitions: [],
              hash: ""
            },
            skills: %{
              always_instructions: "",
              hash: ""
            },
            changed_paths: []
end
