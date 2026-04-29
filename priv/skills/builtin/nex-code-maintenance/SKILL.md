---
name: nex-code-maintenance
description: Use when modifying NexAgent framework CODE, runtime activation, self_update deploy or rollback, ReqLLM/provider adapters, model/provider config contracts, or CODE-layer tests.
user-invocable: false
---

# Nex CODE Maintenance

Use this skill for NexAgent framework CODE changes. Workbench app artifacts, notes, memory, SOUL, USER, and ordinary workspace data are not CODE unless the change touches `lib/nex/agent/**`, `priv/workbench/**`, tests, or other framework implementation files.

## CODE Lane

Use the CODE lane for framework implementation changes:

```text
find/read/reflect -> apply_patch -> self_update status -> self_update deploy
```

Rules:

- Discover code with `find` first unless the exact module/path is already known.
- Use `reflect source` when inspecting an Elixir module by name.
- Use `read` when inspecting known files or docs.
- Modify files with `apply_patch`.
- File edits only write disk. Runtime activation for CODE changes requires `self_update deploy`.
- The current turn may still run old code until deploy succeeds.
- `self_update status` is the deploy preflight entrypoint.
- `self_update deploy` is the quick deploy verification path.
- Strict ship checks such as format, credo, dialyzer, or broad suites are explicit extra confidence checks, not mandatory on every quick deploy loop.
- Subagents may inspect and patch code, but only the owner run may use `self_update status`, `self_update deploy`, or `self_update rollback`.

## Layer Boundary

Route changes before editing:

- `SOUL`: persona, values, voice, operating style.
- `USER`: user profile and collaboration preferences.
- `MEMORY`: durable facts and workflow lessons.
- `SKILL`: reusable procedural guidance.
- `TOOL`: deterministic executable capability.
- `CODE`: framework implementation, runtime behavior, tests, prompts owned by code.

Do not use CODE changes for a durable instruction when a skill or memory entry is the right layer.

## Provider And ReqLLM Work

Provider differences belong under provider adapters, not scattered across generic runner code.

Rules:

- Keep `ReqLLM` as the provider-agnostic facade.
- Put provider-specific request policy under `Nex.Agent.LLM.Providers.*`.
- Register provider adapters through `ProviderRegistry`.
- Keep first-party `openai` and third-party `openai-compatible` behavior separate.
- `openai-compatible` maps to OpenAI wire protocol through its adapter and owns compatible request-option promotion.
- Anthropic-compatible `tool_choice` uses `%{type: "tool", name: "tool_name"}`.
- Do not use OpenAI function-style `tool_choice` for Anthropic-compatible APIs.

When touching model/provider config, also check runtime reload projection and affected tests so config, runtime snapshot, docs, and tool/provider behavior stay aligned.

## Verification

Pick the narrowest useful checks:

- CODE prompt/tool/skill changes: `context_builder_test`, `skills_test`, `runtime_test`, `tool_alignment_test`.
- Provider changes: provider registry/profile/ReqLLM tests and impacted adapter tests.
- Workbench core changes: focused Workbench tests plus compile.
- Runtime activation changes: `self_update` focused tests and deploy/status paths.

Report what was changed and what was verified. If broad suites fail in unrelated known areas, separate baseline failures from the current change.
