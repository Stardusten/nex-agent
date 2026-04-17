# 2026-04-16 Runtime Reload Architecture

## Summary

The repo should treat runtime behavior as a single reloadable snapshot instead of letting modules read config and workspace context independently.

The reload scope includes three groups:

1. Runtime config
   - `~/.nex/agent/config.json`
   - workspace executor configs
2. Runtime context layers
   - `AGENTS.md`
   - `SOUL.md`
   - `USER.md`
   - `TOOLS.md`
   - `memory/MEMORY.md`
3. Runtime capability registries
   - `Nex.Agent.Tool.Registry`
   - `Nex.Agent.Skills`

## Current Behavior

- `Nex.Agent.Config.load/0` reads config directly from disk each time it is called.
- `Nex.Agent.ContextBuilder.build_system_prompt/1` reads bootstrap files on each prompt build.
- `Nex.Agent.Runner` fetches tool definitions from `Tool.Registry` on each LLM call.
- Channel processes load config at `init/1` and then keep long-lived state locally.
- `Nex.Agent.SystemPrompt` is not a real prompt cache right now; `invalidate_cache/1` is a no-op.
- `Nex.Agent.InboundWorker` keeps agent structs in memory, so an existing session can continue running with stale runtime options even when prompt layers are rebuilt per turn.

## Decided Architecture

Introduce a unified runtime layer built around a versioned snapshot.

Core components:

1. `Nex.Agent.Runtime`
   - single authoritative runtime snapshot source
   - stores current snapshot, last valid snapshot, version, and changed paths
2. `Nex.Agent.Runtime.Watcher`
   - detects changes under config and workspace runtime files
   - debounces change bursts
   - asks `Nex.Agent.Runtime` to rebuild
3. `Nex.Agent.Runtime.Snapshot`
   - normalized shape for config, prompt layers, tool definitions, skill catalog, and metadata hashes
4. `Nex.Agent.Runtime.Reconciler`
   - receives runtime version changes
   - updates lightweight consumers in place
   - reconnects or restarts only the modules that must refresh long-lived state

## Runtime Startup Order

Runtime startup order is frozen.

`Nex.Agent.Runtime` must start:

- after `Nex.Agent.Skills`
- after `Nex.Agent.InfrastructureSupervisor` has started `Nex.Agent.Tool.Registry`
- before `Nex.Agent.WorkerSupervisor`
- before `Nex.Agent.Gateway`

Reason:

- the initial runtime snapshot must read the already-started `Skills` cache
- the initial runtime snapshot must read the already-started `Tool.Registry` definitions
- downstream workers and gateway must not start against an undefined runtime snapshot

Phase 1 initial boot behavior is also frozen:

- initial snapshot build failure is fail-fast
- do not boot the application in a long-lived `runtime_unavailable` degraded mode during phase 1
- `{:error, reason}` from initial runtime startup should fail application startup so the mismatch is visible immediately

## Authoritative Resolvers

The runtime workspace resolver is frozen to:

- `Keyword.get(opts, :workspace) || Nex.Agent.Workspace.root(opts)`

`Nex.Agent.SystemPrompt` still contains an older hard-coded workspace constant, but it is not authoritative for runtime reload work and must not be used as the workspace truth source.

## Snapshot Build Order

Snapshot build order is frozen.

`Runtime.reload/1` must execute these steps in order:

1. resolve authoritative workspace
2. load config from authoritative config path
3. build prompt layers from workspace files
4. build tool definitions from the current `Tool.Registry` state
5. build skills `always_instructions` from the current `Nex.Agent.Skills` state
6. assemble snapshot candidate
7. validate snapshot candidate
8. publish new version only after the candidate is complete

This order means:

- `Runtime.reload/1` does not mutate `Tool.Registry` or `Nex.Agent.Skills`
- registry or skills refresh must happen before calling `Runtime.reload/1` when file changes affect them
- `Runtime.Reconciler` must not reload registry/skills after a version is already published, because that would create a false-consistent snapshot

## Snapshot Rules

Each runtime snapshot must be built atomically and carry one monotonic version.

The snapshot should include at least:

```elixir
%Nex.Agent.Runtime.Snapshot{
  version: pos_integer(),
  config: %Nex.Agent.Config{},
  workspace: String.t(),
  prompt: %{
    system_prompt: String.t(),
    diagnostics: [map()],
    files: %{String.t() => binary()},
    hash: String.t()
  },
  tools: %{
    definitions_all: [map()],
    definitions_subagent: [map()],
    definitions_cron: [map()],
    hash: String.t()
  },
  skills: %{
    always_instructions: String.t(),
    catalog_hash: String.t()
  },
  changed_paths: [String.t()]
}
```

The exact struct can grow, but the runtime version contract is fixed:

- one version equals one coherent world view
- no consumer should combine prompt from version `N` with tools from version `N-1`

Phase 1 boundary:

- tool registry definitions are inside the runtime version contract
- `Skills.always_instructions/1` is inside the runtime version contract
- skill-runtime selected packages and ephemeral tools are not inside the persisted runtime snapshot in phase 1
- skill-runtime selected packages and ephemeral tools remain per-turn data prepared inside `Runner`
- therefore phase 1 consistency target is:
  - base prompt layers + base tool definitions + always-on skill instructions + agent runtime_version

## Agent Staleness Rule

Existing session history must stay.

Existing in-memory agent structs may be discarded and rebuilt on the next user turn when the runtime version changes.

This is the preferred behavior for:

- provider/model/api_key/base_url changes
- tool definition changes
- prompt layer changes
- max iteration changes

Do not try to mutate every live agent in place.

The concrete field is frozen to `runtime_version` on `%Nex.Agent{}`.

Required write points:

- `Nex.Agent.start/1`
- `Nex.Agent.InboundWorker.ensure_agent/4`
- cache write-back after `Nex.Agent.prompt/3`

## Channel Reload Rule

Do not restart `Nex.Agent.Gateway` for config changes.

Reload by child process:

- lightweight config changes: apply in place where practical
- connection-affecting config changes: reconnect or restart only that channel child
- if state migration is not essential, prefer reconnect over complex migration

## Tool Visibility Rule

`TOOLS.md` is documentation only. Actual model-callable tools come from runtime tool definitions.

A change is complete only when all of the following move to the same runtime version:

- prompt layer text
- tool registry definitions
- always-on skill instructions
- session agent runtime version marker

This prevents the “tool exists but the model cannot see or use it” failure mode.
