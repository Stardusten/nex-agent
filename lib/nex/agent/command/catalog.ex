defmodule Nex.Agent.Command.Catalog do
  @moduledoc """
  Unified user-facing slash command catalog.

  This catalog is the truth source for cross-platform command behavior.
  Channels may project these commands into native platform surfaces, but the
  execution contract remains owned by the shared command layer.
  """

  @type command_name :: String.t()

  @type definition :: %{
          required(:name) => command_name(),
          required(:description) => String.t(),
          required(:usage) => String.t(),
          required(:bypass_busy?) => boolean(),
          required(:native_enabled?) => boolean(),
          required(:handler) => atom(),
          optional(:channels) => [String.t()]
        }

  @definitions [
    %{
      name: "new",
      description: "reset the current chat session",
      usage: "/new",
      bypass_busy?: true,
      native_enabled?: true,
      handler: :new,
      channels: ["feishu", "discord"]
    },
    %{
      name: "stop",
      description: "stop the current task and clear queued messages",
      usage: "/stop",
      bypass_busy?: true,
      native_enabled?: true,
      handler: :stop,
      channels: ["feishu", "discord"]
    },
    %{
      name: "commands",
      description: "list supported slash commands for this chat",
      usage: "/commands",
      bypass_busy?: true,
      native_enabled?: true,
      handler: :commands,
      channels: ["feishu", "discord"]
    },
    %{
      name: "status",
      description: "show current owner run status immediately",
      usage: "/status",
      bypass_busy?: true,
      native_enabled?: true,
      handler: :status,
      channels: ["feishu", "discord"]
    },
    %{
      name: "model",
      description: "show or switch the current chat session model",
      usage: "/model [name|number|reset]",
      bypass_busy?: true,
      native_enabled?: true,
      handler: :model,
      channels: ["feishu", "discord"]
    },
    %{
      name: "queue",
      description: "queue a message for the next owner turn",
      usage: "/queue <message>",
      bypass_busy?: true,
      native_enabled?: true,
      handler: :queue,
      channels: ["feishu", "discord"]
    },
    %{
      name: "btw",
      description: "ask a side question without interrupting the owner run",
      usage: "/btw <message>",
      bypass_busy?: true,
      native_enabled?: true,
      handler: :btw,
      channels: ["feishu", "discord"]
    }
  ]

  @spec definitions() :: [definition()]
  def definitions do
    @definitions
  end

  @spec runtime_definitions() :: [map()]
  def runtime_definitions do
    Enum.map(@definitions, fn definition ->
      %{
        "name" => Map.fetch!(definition, :name),
        "description" => Map.fetch!(definition, :description),
        "usage" => Map.fetch!(definition, :usage),
        "bypass_busy?" => Map.fetch!(definition, :bypass_busy?),
        "native_enabled?" => Map.fetch!(definition, :native_enabled?),
        "handler" => definition |> Map.fetch!(:handler) |> Atom.to_string(),
        "channels" => definition |> Map.fetch!(:channels) |> Enum.map(&to_string/1)
      }
    end)
  end

  @spec get(String.t()) :: definition() | nil
  def get(name) when is_binary(name) do
    Enum.find(@definitions, &(Map.get(&1, :name) == name))
  end
end
