---
name: memory-and-evolution-routing
description: Use when deciding whether to route a durable change into MEMORY, USER, SOUL, SKILL, TOOL, or CODE; processing user corrections; or routing self-improvement/evolution candidates during the memory-system reset.
user-invocable: false
---

# Memory And Evolution Routing

Use this skill when a user asks the agent to remember something, corrects the agent's self-model or workflow assumptions, or asks the agent to improve itself.

## Layer Routing

Choose the highest layer that solves the need:

- `SOUL`: persona, values, voice, operating style.
- `USER`: user profile, preferences, timezone, communication style, collaboration expectations.
- `MEMORY`: environment facts, project conventions, durable operational context, reusable workflow lessons.
- `SKILL`: reusable multi-step workflows and procedural knowledge.
- `TOOL`: deterministic executable capabilities.
- `CODE`: internal implementation upgrades.

Do not persist one-off outputs, temporary investigation notes, raw TODO lists, or facts that are easy to rediscover.

## Current Reset Boundary

The legacy file-backed memory toolchain has been removed during the current reset.

- Do not call `memory_consolidate`, `memory_status`, `memory_rebuild`, or `memory_write`.
- Do not inspect or rely on `memory/MEMORY.md` as a runtime truth source.
- If the user asks to "remember" something during this reset window, route it to the right surviving layer instead:
  - `USER.md` for user profile and collaboration preferences
  - `SOUL.md` for persona/style
  - `SKILL` for reusable workflow knowledge
  - `CODE` for framework behavior
- If the request truly needs a new long-term memory capability, treat it as design/implementation work for the upcoming plugin-based memory system rather than trying to revive the retired path.

When asked whether memory was updated or previously triggered, answer from the current reset state: the old automatic memory runtime is removed, and the replacement plugin-based path is not yet active unless explicitly implemented.

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

Evolution proposes candidates first. It must not automatically deploy, patch, write skills, or edit SOUL.

Owner-approved execution goes through the single `evolution_candidate` lane:

- use `evolution_candidate list` / `show` to inspect derived candidate lifecycle
- use `evolution_candidate approve` / `reject` only as the owner run
- soul/skill candidates must reuse existing deterministic write tools
- code candidates must still flow through `apply_patch` and `self_update deploy`

Do not add parallel candidate state files or parallel approval tools.
