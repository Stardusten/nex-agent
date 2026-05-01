# 2026-05-01 Codex Sandbox Approval Model

## Summary

Codex treats command safety as two separate layers:

- sandbox policy controls the OS boundary for spawned commands
- approval policy controls when a human may authorize running outside or beyond that boundary

The key behavior is not "retry every failed command outside the sandbox." In the recommended `on-request` mode, commands run sandboxed by default, and the model may explicitly request elevated permissions when it already knows the command needs network, GUI/native host access, or filesystem access outside the current sandbox. The old `on-failure` behavior is the optimistic retry mode: run in sandbox first, then ask to rerun unsandboxed only after a sandbox failure. Codex marks that mode deprecated for interactive use.

## Source References

- `codex --help` exposes the public contract:
  - `--sandbox read-only|workspace-write|danger-full-access`
  - `--ask-for-approval untrusted|on-failure|on-request|never`
  - `on-request`: model decides when to ask for approval
  - `on-failure`: sandbox first, then ask for unsandboxed execution after failure
  - `--dangerously-bypass-approvals-and-sandbox`: no prompts and no sandbox, only for externally sandboxed environments
- Codex approvals docs: `on-request` prompts when the agent needs to escape the sandbox and auto-approves work that stays inside sandbox boundaries.
  - https://www.mintlify.com/openai/codex/concepts/approvals
- Codex source `exec_policy.rs`:
  - unmatched non-dangerous commands in restricted sandbox are allowed to run sandboxed
  - commands that request sandbox override become `Prompt` under `on-request`
  - `bypass_sandbox` is only true when every parsed command segment is explicitly allowed by execpolicy
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/core/src/exec_policy.rs
- Codex source `request_permissions.rs`:
  - runtime permission requests carry `network` and `file_system` permission profiles
  - grants can be scoped to turn or session
  - https://raw.githubusercontent.com/openai/codex/main/codex-rs/protocol/src/request_permissions.rs
- Codex model-visible prompt includes a dedicated permissions instruction block:
  - filesystem sandbox mode and network policy are stated before tool use
  - the model is told to use `sandbox_permissions: "require_escalated"` plus `justification` when a command needs host access
  - the prompt lists up-front escalation cases such as network/registry access, GUI app launch, writes outside sandbox roots, and likely sandbox-related failures

## Correct Mental Model

Codex has three practical execution paths:

1. Sandboxed default execution.
   - The command runs under the active sandbox profile.
   - Network may be restricted.
   - Filesystem writes are limited to workspace/writable roots.
   - Failure is reported to the model as a normal tool result.

2. Explicit runtime permission request.
   - The model asks for more permission before running the command.
   - Approval UI shows the command and reason.
   - If approved, the current command can run with extra network/filesystem permissions or outside the sandbox, depending on the requested permission profile and client policy.

3. Dangerous bypass mode.
   - Configured by user/operator, not inferred from command failure.
   - Disables both approval prompts and sandboxing.
   - Only safe when an outer sandbox already exists.

`on-failure` is distinct from `on-request`. It may cause the "fail once, ask, rerun" shape, but that is not the recommended default for interactive long-running agents.

## Implications For NexAgent

For NexAgent Phase 21, the aligned first implementation should be:

- keep `Sandbox.Exec` as the only child-process execution path
- default bash execution remains sandboxed with restricted network
- expose sandbox limitations clearly in tool errors so the model can decide whether elevation is needed
- add an explicit bash tool parameter for requesting elevated execution, requiring a human approval request before execution
- include steady system-prompt guidance that tells the model some sandboxed command results may be wrong or incomplete and that it should request elevation up front when host access is known to be required
- approved elevated execution runs the exact command with `mode: :danger_full_access`, `backend: :noop`, and `network: :enabled`
- elevated execution approval is once-only; it must not offer or accept session/similar/always grants until an execpolicy-equivalent rule system exists
- do not implement automatic unsandboxed retry on failure
- do not implement full Codex execpolicy yet
- do not broadly approve command families for elevated execution in the first cut

This keeps the model-facing behavior close to Codex `on-request`: the model can ask for elevated execution up front when it knows the sandbox boundary is the problem, while ordinary commands still run once under sandbox.

## Boundaries

- Hard protected paths remain a NexAgent policy requirement. Unsandboxed execution can technically bypass OS-level path enforcement, so elevated execution must be exact-command approval only in the first version and should be treated as high risk in UI/metadata.
- Session, similar, and always grants for elevated commands are blocked in the first version. A user approving an elevated command once does not imply future approval for the same command or command family in a different context.
- Network enablement should not become the global default just to support package managers or local bridge tools.
