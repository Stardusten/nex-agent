---
name: memory-and-evolution-routing
description: Use when deciding whether to write MEMORY, USER, SOUL, SKILL, TOOL, or CODE; handling memory refresh/status/rebuild; processing user corrections; or routing self-improvement/evolution candidates.
user-invocable: false
---

# Memory And Evolution Routing

Use this skill when a user asks the agent to remember something, corrects the agent's self-model or workflow assumptions, asks whether memory updated, requests memory refresh/rebuild, or asks the agent to improve itself.

## Layer Routing

Choose the highest layer that solves the need:

- `SOUL`: persona, values, voice, operating style.
- `USER`: user profile, preferences, timezone, communication style, collaboration expectations.
- `MEMORY`: environment facts, project conventions, durable operational context, reusable workflow lessons.
- `SKILL`: reusable multi-step workflows and procedural knowledge.
- `TOOL`: deterministic executable capabilities.
- `CODE`: internal implementation upgrades.

Do not persist one-off outputs, temporary investigation notes, raw TODO lists, or facts that are easy to rediscover.

## Memory Tools

Use the dedicated memory tools when they directly match the request:

- `memory_consolidate`: user explicitly asks to trigger memory refresh now.
- `memory_status`: user asks to check refresh status or whether refresh is running.
- `memory_rebuild`: user explicitly wants a full rebuild from session history.
- `memory_write`: persist a durable memory fact when the user clearly wants it saved or the fact is stable and important.

When a built-in memory tool directly matches, call it before inspecting implementation with `read` or `bash`.

When asked whether memory was updated or previously triggered, inspect MEMORY and current session/runtime state before answering. Empty `MEMORY.md` does not prove this is the first conversation or that no prior session history exists.

## User Corrections

Treat corrections about self-model, product concepts, workflow assumptions, or collaboration preferences as self-improvement signals.

Route them:

- durable self-description or product identity -> `IDENTITY.md` / CODE-owned prompt if truly system-level
- persona/style -> `SOUL`
- user preference -> `USER`
- factual project/environment context -> `MEMORY`
- reusable procedure -> `SKILL`
- missing deterministic capability -> `TOOL`
- runtime implementation bug -> `CODE`

## Evolution Candidates

Evolution proposes candidates first. It must not automatically deploy, patch, write memory, write skills, or edit SOUL.

Owner-approved execution goes through the single `evolution_candidate` lane:

- use `evolution_candidate list` / `show` to inspect derived candidate lifecycle
- use `evolution_candidate approve` / `reject` only as the owner run
- memory/soul/skill candidates must reuse existing deterministic write tools
- code candidates must still flow through `apply_patch` and `self_update deploy`

Do not add parallel candidate state files or parallel approval tools.
