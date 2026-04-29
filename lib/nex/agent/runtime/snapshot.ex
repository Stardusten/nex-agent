defmodule Nex.Agent.Runtime.Snapshot do
  @moduledoc """
  Immutable runtime world view used by the agent main path.
  """

  alias Nex.Agent.Runtime.Config

  @type t :: %__MODULE__{
          version: pos_integer(),
          config_path: String.t() | nil,
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
            profiles: %{optional(String.t()) => Nex.Agent.Capability.Subagent.Profile.t()},
            definitions: [map()],
            hash: String.t()
          },
          skills: %{
            cards: [map()],
            catalog_prompt: String.t(),
            diagnostics: [map()],
            hash: String.t()
          },
          hooks: %{
            entries: [map()],
            diagnostics: [map()],
            path: String.t() | nil,
            version: pos_integer(),
            hash: String.t()
          },
          plugins: %{
            manifests: [map()],
            enabled: [String.t()],
            contributions: %{
              channels: [map()],
              providers: [map()],
              tools: [map()],
              skills: [map()],
              commands: [map()]
            },
            diagnostics: [map()],
            hash: String.t()
          },
          workbench: %{
            runtime: map(),
            apps: [map()],
            diagnostics: [map()],
            hash: String.t()
          },
          changed_paths: [String.t()]
        }

  defstruct version: nil,
            config_path: nil,
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
              cards: [],
              catalog_prompt: "",
              diagnostics: [],
              hash: ""
            },
            hooks: %{
              entries: [],
              diagnostics: [],
              path: nil,
              version: 1,
              hash: ""
            },
            plugins: %{
              manifests: [],
              enabled: [],
              contributions: %{
                channels: [],
                providers: [],
                tools: [],
                skills: [],
                commands: []
              },
              diagnostics: [],
              hash: ""
            },
            workbench: %{
              runtime: %{},
              apps: [],
              diagnostics: [],
              hash: ""
            },
            changed_paths: []
end
