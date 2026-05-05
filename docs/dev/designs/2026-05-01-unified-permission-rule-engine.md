# 2026-05-01 Unified Permission Rule Engine

## Context

The first permission-rule implementation solved repeated command approvals, but it still carried the wrong center of gravity:

- the rule engine treated command approvals as the primary case;
- path approvals still used legacy grant keys;
- `command`, `path`, `network`, and tool invocation were modeled as separate request kinds instead of one permission event with multiple effects;
- the model had no explicit way to ask the user to approve a durable rule.

The intended model is more general:

```text
Raw tool event -> enrich into semantic requirements -> evaluate rules -> decision
```

Callers provide only trusted raw facts. The rule system owns command tokenization, path normalization, risk classification, operation inference, rule matching, specificity ranking, and rule proposals.

## First Principles

A permission decision answers one question:

> May this actor, in this context, use this tool call to produce these effects?

The primitive input is a tool event, not a command event or path event.

```elixir
%RawToolEvent{
  tool_name: "bash",
  params: %{"command" => "cat /Users/krisxin/Desktop/a.md | wc -l"},
  workspace: "/Users/krisxin/Desktop/nex-agent",
  cwd: "/Users/krisxin/Desktop/nex-agent",
  channel: "discord",
  chat_id: "thread_123",
  actor: %ActorRef{kind: :user, channel: "discord", id: "user_1"},
  metadata: %{}
}
```

The enriched event may have multiple semantic tags:

```elixir
%EnrichedPermissionEvent{
  raw: RawToolEvent.t(),
  tags: MapSet.new([:tool, :command, :filesystem, :read]),
  command_tokens: ["cat", "/Users/krisxin/Desktop/a.md", "|", "wc", "-l"],
  risk_class: :read,
  requirements: [
    %PermissionRequirement{
      resource: :command,
      operation: :execute,
      target: "cat /Users/krisxin/Desktop/a.md | wc -l",
      attrs: %{command_program: "cat"}
    },
    %PermissionRequirement{
      resource: :path,
      operation: :read,
      target: "/Users/krisxin/Desktop/a.md",
      attrs: %{path: "/Users/krisxin/Desktop/a.md"}
    }
  ]
}
```

The important invariant is requirement coverage:

```text
An event is allowed only when every relevant requirement is allowed.
One denied requirement denies the whole event.
One asked requirement asks for the whole event.
```

This prevents a read rule from accidentally approving a read-and-write command.

For bash, command execution remains an explicit requirement. A command like
`ls /Users/krisxin/Desktop/project` therefore has both `command:execute` and
`path:list` requirements. A path rule only covers the path requirement; it does
not implicitly approve shell execution. This keeps the rule model uniform and
lets debug output show exactly which requirement remains uncovered.

## Rule Shape

Rules are data predicates over an enriched event and one requirement.

```elixir
%Rule{
  id: "thread-read-desktop",
  level: 0,
  effect: :allow,
  scope: :thread,
  predicates: [
    {:eq, :channel, "discord"},
    {:eq, :chat_id, "thread_123"},
    {:resource_eq, :path},
    {:operation_in, [:read, :list, :search, :stat, :stream]},
    {:path_under, "/Users/krisxin/Desktop"}
  ],
  reason: "Allow this Discord thread to read Desktop files",
  created_by: %ActorRef{},
  created_at: ~U[2026-05-01 00:00:00Z],
  expires_at: nil,
  source: :owner_grant
}
```

There is no top-level `kind: :command | :path`. A rule may constrain tool, command, path, network, actor, channel, execution mode, or any combination of those.

There is also no top-level `execution`. Sandboxed/elevated execution is a property of the event or command requirement and can be matched with a predicate such as:

```elixir
{:eq, :requested_execution, :elevated}
```

## Predicate Set

The first unified cut keeps predicates explicit and explainable:

- `{:eq, field, value}`
- `{:in, field, values}`
- `{:contains, field, value}`
- `{:tag_in, tags}`
- `{:resource_eq, resource}`
- `{:operation_in, operations}`
- `{:path_eq, path}`
- `{:path_under, root}`
- `{:exact, :command_tokens, tokens}`
- `{:prefix, :command_tokens, tokens}`
- `{:risk_in, risk_classes}`
- `{:scope_eq, scope}`

No arbitrary regex or code predicates. Any new predicate must have a deterministic renderer, canonical fingerprint, and specificity score.

## Decision Semantics

The rule engine evaluates every requirement independently, then folds the requirement decisions into one event decision.

Requirement rule ordering:

```text
1. Higher level wins.
2. Within the same level, more specific matching rule wins.
3. When level and specificity tie, stricter effect wins.
4. If nothing matches a requirement, that requirement asks.
```

Initial levels:

```text
level 0 = ordinary owner/workspace/session policy
level 1 = framework/system invariant policy
```

Strictness:

```text
deny > ask > allow
```

Event folding:

```text
any requirement denied => deny
else any requirement asked => ask
else allow
```

## Path Permissions

Path permissions are ordinary rules over `:path` requirements.

Examples:

```elixir
# Allow this thread to read a whole tree.
[
  {:resource_eq, :path},
  {:operation_in, [:read, :list, :search, :stat, :stream]},
  {:path_under, "/Users/krisxin/Desktop"}
]

# Allow this thread to write a generated output directory.
[
  {:resource_eq, :path},
  {:operation_in, [:write, :mkdir]},
  {:path_under, "/Users/krisxin/Desktop/output"}
]
```

Path enrichment must canonicalize paths before matching, including symlink-aware nearest-existing-ancestor handling for writes to missing files. Hard protected paths remain enforced by sandbox policy before any owner-grant allow can take effect.

## Tool Scope

The target end state is that all resource-touching tools go through the permission engine:

- deterministic filesystem tools produce path requirements;
- `bash` produces a command requirement and conservative inferred path/network requirements when available;
- HTTP/network tools produce network requirements;
- self-update and process tools produce process/code-update requirements.

The rule engine decides; enforcement still belongs to the tool boundary:

- direct file tools must use `Sandbox.FileSystem`;
- sandboxed bash must rely on the OS sandbox backend for syscall enforcement;
- elevated bash cannot be file-by-file constrained after launch and must remain a coarser, higher-risk approval;
- plugin BEAM code is not sandboxed merely because a rule exists.

## Approval UX

The ordinary approval surface stays small:

```text
Approval required: Allow read access to /Users/krisxin/Desktop/a.md

Rule: Allow read under /Users/krisxin/Desktop in this thread.

[Allow once] [Allow rule] [Decline]
```

`Allow rule` approves exactly the single rule shown above the buttons. Broader or more complex durable changes should be requested through a separate model-facing rule proposal tool, not by adding more buttons to every approval prompt.

## Model-Facing Permission Tools

The model-facing surface uses provider-safe double-underscore namespaces. Colon
names such as `permission:add_rule` are reserved for conceptual discussion only,
because common LLM tool-call APIs reject colons in function tool names.

```text
permission__add_rule
permission__list_rules
permission__revoke_rule
permission__debug__decision
```

Each model-facing tool is an atomic capability, not a large management tool with
an `action` parameter. This keeps future namespace lazy-loading natural:
`permission__*` is the permission capability family, and `permission__debug__*`
can grow into a sub-family without changing the naming convention.

`permission__add_rule` creates a pending approval request that says what rule
will be added. It must not write the rule before owner approval.

`permission__add_rule` accepts raw, user-understandable intent such as:

```json
{
  "effect": "allow",
  "scope": "thread",
  "operations": ["read", "list"],
  "path_under": "/Users/krisxin/Desktop",
  "reason": "Need to repeatedly inspect Desktop project files in this thread"
}
```

The implementation normalizes this into the same `%Rule{}` IR and passes it through the same conflict checks and persistence path as UI-generated rules.

`permission__list_rules` returns a semantic rule view for the current permission
context. It returns stable `rule_ref` values, summaries, scope, effect,
persistence, and whether a rule is removable. It must not expose storage paths,
hashes, manifests, or raw persistence records.

`permission__revoke_rule` revokes one removable rule by `rule_ref`. The first
cut only allows direct revocation of ordinary level-0 owner-approved allow
rules. Removing deny, ask, or framework/system rules is not allowed through this
tool because that can increase effective authority.

`permission__debug__decision` evaluates one raw event against the current
approved permission state. When candidate rules are supplied, the same tool also
evaluates candidate-only and current-plus-candidate decisions.

The result must include the enriched requirements, per-requirement action,
matched rule ids, and uncovered requirements. The model must use this tool
instead of inspecting any private permission internals. This is the preferred
way to discover that a path rule did not cover `command:execute`, or that a
command rule still needs a companion path rule for a path-touching bash command.

## Storage

Rule storage is a private implementation detail behind `PermissionRuleStore`.
Model-facing prompts, skills, and tools must not expose where rules live or ask
the model to inspect or mutate stored rule records directly. The backing store
may be a local file, embedded database, or remote rule service without changing
the model-facing contract.

The current implementation uses append-only, tamper-evident records. Tamper
evidence is not local tamper resistance. On load, invalid tails are ignored, a
ControlPlane observation is emitted, and invalid allow rules must never become
effective.
