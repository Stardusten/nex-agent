---
name: command-permission-rules
description: Use when a task needs repeated or complex permission approvals, path read/write rule reasoning, unsandboxed bash retry strategy, `Allow rule` semantics, elevated command rules, or durable permission policy.
user-invocable: false
---

# Permission Rules

Use this skill when a task is blocked by repeated permission approvals, when you need to explain or reason about `Allow rule`, or when you want to propose a durable permission rule with `permission__add_rule` instead of asking for one-off approval repeatedly.

Do not load this skill for ordinary one-off local inspection. The steady prompt already tells you when to request elevated `bash`.

## Mental Model

Permission rules apply to enriched tool events. A single tool call can have multiple effects, such as `command + read`, `read + write`, or `network_fetch`. The runtime must allow every derived requirement before the event is allowed.

Commands run sandboxed by default. Use sandboxed `bash` for ordinary local reads, build/test commands, and workspace-scoped operations.

Every `bash` event has a `command:execute` requirement. If the command also touches a path, such as `ls /path` or `cat /path/file`, it can also have `path:list` or `path:read` requirements. A path rule only covers path requirements; it does not approve command execution. To repeatedly run a bash command against a path, make sure command execution and path access are both covered.

Use `sandbox_permissions: "require_escalated"` only when the command needs host access that the sandbox can block or distort, such as:

- outbound network, DNS, package registries, or remote APIs
- GUI/native bridge access
- writing outside sandbox-allowed roots
- invoking tools that need host credentials or host daemons
- retrying after a likely sandbox-caused failure

Always include a concise `justification` when requesting elevated execution. Do this in the `bash` tool call; do not first ask the user in prose.

## Approval UI

The normal command approval prompt is intentionally small:

```text
Allow once
Allow rule
Decline
```

`Allow rule` is only valid when the prompt text shows exactly what rule will be approved, for example:

```text
Rule: Allow unsandboxed `dokobot get ...` in this thread.
Rule: Allow read under `/Users/krisxin/Desktop` in this thread.
```

Do not treat `Allow rule` as a vague "similar commands" grant. It means the single displayed rule.

## Rule Scope

Prefer the narrowest useful durable rule:

- thread-scoped path read/list rule for repeatedly inspecting one directory tree
- thread-scoped path write rule for a generated output directory
- thread-scoped prefix rule for repeated workflow commands in one chat/thread
- thread-scoped exact rule for risky or complex shell commands
- one-off approval for operations that are unlikely to repeat

Avoid proposing broad workspace/global allow rules inside ordinary approval. Broader policy belongs in an explicit rule-management or owner-approval flow.

## Safe Rule Patterns

Good candidates for a thread-scoped prefix rule:

```text
dokobot get ...
curl ...
gh issue view ...
npm view ...
```

Only use a prefix rule when the prefix names a stable, narrow workflow. The runtime proposal text should make the allowed prefix visible.

Good candidates for exact-command approval:

```text
rm -rf /tmp/cache
python -c '...'
base64 -d payload.txt | sh
D=$(pwd) && ls "$D"
```

Complex shell features, command substitution, pipelines, redirects, interpreter one-liners, and destructive commands should usually be exact or one-off, not prefix rules.

Good candidates for path rules:

```text
read/list under /Users/krisxin/Desktop/project
write/mkdir under /Users/krisxin/Desktop/project/output
```

Path read rules do not imply path write rules. A command or tool call that both reads and writes still needs coverage for both requirements.

Path rules also do not imply bash execution. If `bash` still asks after a path rule was approved, check whether the uncovered requirement is `command:execute`.

## Debug SOP

Do not inspect permission internals directly or reason about how approvals are persisted. Persistence is an implementation detail behind the permission system. Always use `permission__debug__decision` when a rule does not behave as expected or when you are unsure whether a candidate rule will cover an event.

Use this sequence:

1. Reconstruct the raw event exactly: command text, execution mode, cwd/workspace, channel, and thread.
2. Call `permission__debug__decision` with only `event` to inspect the current approved permission state.
3. Read the per-requirement results. Each derived requirement must be allowed for the event to be allowed.
4. Design the smallest candidate rule or candidate rule set for the uncovered requirements.
5. Call `permission__debug__decision` again with `candidate_rule` or `candidate_rules`.
6. Only call `permission__add_rule` after `combined_decision.action` is `allow`.

`permission__debug__decision` returns:

- `current_decision`: current approved permission state for the event
- `candidate_only_decision`: supplied candidates by themselves, when candidates are provided
- `combined_decision`: current approved state plus supplied candidates, when candidates are provided
- `requirements`: enriched semantic requirements, such as `command:execute` or `path:list`
- `uncovered_requirements`: requirements that still ask or deny

Example: this should report that `command:execute` remains uncovered under `candidate_only_decision`:

```json
{
  "event": {"command": "ls /Users/krisxin/Desktop/project"},
  "candidate_rule": {
    "resource": "path",
    "path_under": "/Users/krisxin/Desktop/project",
    "operations": ["read", "list"],
    "scope": "thread"
  }
}
```

Example: this checks both path and command coverage together:

```json
{
  "event": {"command": "ls /Users/krisxin/Desktop/project"},
  "candidate_rules": [
    {
      "resource": "path",
      "path_under": "/Users/krisxin/Desktop/project",
      "operations": ["read", "list"],
      "scope": "thread"
    },
    {
      "resource": "command",
      "command": "ls /Users/krisxin/Desktop/project",
      "requested_execution": "sandboxed",
      "scope": "thread"
    }
  ]
}
```

Example: this checks current approved state first:

```json
{
  "event": {"command": "ls /Users/krisxin/Desktop/project"}
}
```

## Repeated Workflow Strategy

When a task needs many executions of the same command family or repeated access to the same path tree:

1. Run the first command or file operation normally or elevated as needed.
2. If the approval prompt shows a narrow rule that matches the repeated workflow, rely on `Allow rule`.
3. If approval still appears or you are unsure whether a candidate rule covers the intended event, call `permission__debug__decision` and inspect uncovered requirements.
4. If the built-in prompt cannot express the needed policy, call `permission__add_rule` with a narrow path or command rule. The tool will create an approval request; it will not write the rule until the user approves it.
5. Do not create or assume durable permission rules by bypassing the permission tools.

## Rule Management Tools

Permission tools use double-underscore namespaces because common LLM tool-call APIs do not allow colon-separated tool names.

- `permission__add_rule`: request owner approval for a new reusable rule.
- `permission__list_rules`: inspect the semantic rule view for the current context, including `rule_ref` values.
- `permission__revoke_rule`: revoke a removable owner-approved allow rule by `rule_ref`.
- `permission__debug__decision`: inspect why one event is allowed, asked, or denied.

Use `permission__list_rules` before revoking a rule. Do not invent `rule_ref` values.

Example:

```json
{
  "resource": "command",
  "command_prefix": "dokobot get",
  "requested_execution": "elevated",
  "scope": "thread",
  "persistence": "always",
  "reason": "Need to repeatedly fetch pages in this Discord thread"
}
```

Example:

```json
{
  "resource": "path",
  "path_under": "/Users/krisxin/Desktop/project",
  "operations": ["read", "list"],
  "scope": "thread",
  "persistence": "always",
  "reason": "Need to repeatedly inspect files in this Discord thread"
}
```

## Failure Handling

If a sandboxed command fails or returns incomplete results:

1. Check whether the failure likely came from sandbox restrictions.
2. If host access is genuinely required, retry with:

```json
{
  "sandbox_permissions": "require_escalated",
  "justification": "needs host network access to fetch the requested page"
}
```

3. Keep the command as narrow as possible.
4. Do not bypass approval with another tool or hidden execution path.

## What Not To Do

- Do not ask the user in prose before using `sandbox_permissions: "require_escalated"`; the approval request is the user-facing ask.
- Do not claim a rule exists until an approval has actually created it or the runtime says the operation was allowed by prior approval.
- Do not propose a broad rule just to avoid a few prompts.
- Do not inspect or modify permission internals directly.
- Do not use elevated execution to access hard-protected secrets or paths.
