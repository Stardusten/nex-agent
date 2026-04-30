defmodule Nex.Agent.Sandbox.Policy do
  @moduledoc """
  Platform-neutral filesystem and process sandbox policy.

  This struct is the runtime projection consumed by sandbox backends and direct
  file permission checks. Backend-specific details must stay out of this public
  contract so macOS, Linux, and Windows can share the same caller-facing shape.
  """

  @type backend :: :auto | :seatbelt | :linux | :windows | :noop
  @type mode :: :read_only | :workspace_write | :danger_full_access | :external
  @type network :: :restricted | :enabled
  @type access :: :read | :write | :none
  @type path_ref ::
          {:path, String.t()}
          | {:special, :workspace | :minimal | :tmp | :slash_tmp}

  @type filesystem_entry :: %{
          required(:path) => path_ref(),
          required(:access) => access()
        }

  @type t :: %__MODULE__{
          enabled: boolean(),
          backend: backend(),
          mode: mode(),
          network: network(),
          filesystem: [filesystem_entry()],
          protected_paths: [String.t()],
          protected_names: [String.t()],
          env_allowlist: [String.t()],
          raw: map()
        }

  @default_protected_names [".git", ".agents", ".codex"]
  @default_env_allowlist ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "NO_COLOR"]

  defstruct enabled: true,
            backend: :auto,
            mode: :workspace_write,
            network: :restricted,
            filesystem: [],
            protected_paths: [],
            protected_names: @default_protected_names,
            env_allowlist: @default_env_allowlist,
            raw: %{}

  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}), do: struct(__MODULE__, attrs)

  @spec default_protected_names() :: [String.t()]
  def default_protected_names, do: @default_protected_names

  @spec default_env_allowlist() :: [String.t()]
  def default_env_allowlist, do: @default_env_allowlist
end
