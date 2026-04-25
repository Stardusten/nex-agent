# 2026-04-25 Memory System Cost, Visibility, And Triggering

## Summary

The current memory system is useful because it keeps the core model simple:

- workspace-global durable memory in `memory/MEMORY.md`
- workspace-global user profile in `USER.md`
- channel/session-scoped raw message history in session JSONL
- `last_consolidated` as the per-session review cursor
- serialized background refresh through `MemoryUpdater`

Keep that foundation. The next improvements should target cost, user trust, and write quality without replacing the file-backed memory truth source.

## Current Implementation Observations

### 1. Memory is file-backed and workspace-global

`memory/MEMORY.md` is the durable MEMORY-layer truth source. It is loaded into the system prompt by `ContextBuilder` for every session in the workspace.

`USER.md` is a separate USER-layer truth source. It is also workspace-global and is loaded alongside `AGENTS.md`, `SOUL.md`, and `TOOLS.md`.

Session history is not shared across channel/session keys. Each session stores raw messages and metadata in JSONL under `workspace/sessions/...`.

Practical consequence:

- Feishu, Discord, Telegram, and other channel sessions share `USER.md` and `MEMORY.md`.
- They do not share raw session messages.
- Cross-channel durable facts must be promoted into `MEMORY.md` or `USER.md`.

### 2. Refresh is an LLM consolidation pass

`Memory.refresh/4` reads messages after `last_consolidated`, compacts current `MEMORY.md`, renders the pending segment, and asks an LLM to call an internal `save_memory` tool.

The internal tool currently returns either:

- `noop`
- an updated full `MEMORY.md`

The full-document update model is simple and has worked well in practice because the model can preserve context holistically. It is also token-heavy because the prompt includes current memory and the response can include the full memory document.

### 3. Background refresh is serialized

`MemoryUpdater` coalesces jobs per `{workspace, session_key}` and runs one job at a time. This is an important guardrail because all sessions write the same workspace-level `MEMORY.md`.

This serialization should remain. Without it, two sessions could independently read the same old memory and race to overwrite each other's durable facts.

### 4. Refresh is currently too hidden

The system records ControlPlane observations such as `memory.refresh.job.finished`, but the user does not see when memory changed or what was learned.

This makes the system feel implicit:

- users cannot easily trust memory writes
- users cannot correct a bad memory immediately
- users cannot distinguish "the assistant remembered this" from "the assistant merely replied"

A visible notice after successful memory updates would make the behavior more legible.

### 5. Refresh model choice should be independent

Memory refresh currently tends to inherit the model/provider of the owner run or explicit tool context. That is wasteful when the owner run uses an expensive model.

Memory refresh should have a separate model role:

```text
memory_model -> cheap_model -> default_model
```

This keeps the good current behavior while making routine consolidation cheaper. Full rebuild can still use the same role; if higher quality is needed, configure `memory_model` accordingly.

### 6. Triggering is useful but noisy

The current system is aggressive enough that it rarely forgets. That is a real product strength.

The downside is that refresh may run after many turns that contain no durable facts. Even when the model returns noop, those calls still spend tokens. If the model updates too eagerly, memory can accumulate low-value facts.

This finding does not recommend changing trigger frequency in the first implementation step. It should be handled after cost and visibility are fixed, because notice and observations will make later tuning easier to evaluate.

### 7. Current trigger ownership is somewhat scattered

Memory refresh can be enqueued from multiple places:

- `Nex.Agent.prompt/3`
- `Runner.finalize_evolution_turn/5`
- `InboundWorker` after final outbound delivery
- explicit memory tools

`MemoryUpdater` coalescing keeps this from being catastrophic, but the control model is not as crisp as it could be. A later refactor should make owner-run completion the single automatic refresh lane.

## Decided Next Step

Phase 17 should do only two product-visible improvements:

1. Add independent memory refresh model selection.
2. Add user-visible memory update notices.

The intended notice shape is:

```text
🧠 Memory - <summary>
```

Rules:

- send only when `MEMORY.md` actually changes
- do not send on noop
- do not send from cron, follow-up, subagent, or silent/internal contexts
- use a single renderer/helper for all memory mutation paths
- record summary and before/after hash in ControlPlane

## Future Optimization Directions

### 1. Gate refresh by durable-signal detection

After Phase 17, consider replacing "refresh after every owner turn" with:

- immediate refresh for explicit "remember this" signals
- delayed/coalesced refresh after a burst of conversation
- threshold-based refresh after N unreviewed messages
- skip refresh when the turn already used `memory_write`
- cheap classifier or deterministic heuristics before spending a consolidation call

Do not start here. First make memory updates visible and measurable.

### 2. Move incremental refresh from full document update to operations

The current full `MEMORY.md` rewrite is simple but expensive. A later design can introduce structured operations:

```elixir
%{
  "status" => "noop" | "update",
  "ops" => [
    %{
      "op" => "append" | "replace" | "delete",
      "section" => String.t(),
      "content" => String.t(),
      "rationale" => String.t()
    }
  ],
  "summary" => String.t()
}
```

Deterministic merge would reduce output tokens and make notices/audit easier.

Keep full-document rebuild as the safer recovery path.

### 3. Strengthen layer boundaries

The refresh prompt currently mentions "user preferences or stable expectations" as durable memory candidates. That can blur USER and MEMORY.

Preferred direction:

- user profile facts go to `USER.md` via `user_update`
- project/environment/workflow facts go to `MEMORY.md`
- persona/style goes to `SOUL.md`
- project-local facts can go to `projects/<project>/PROJECT.md`

Phase 17 should not implement cross-target memory consolidation, but future refresh design should avoid writing user profile facts into `MEMORY.md`.

### 4. Add dedupe and stale handling

Useful follow-ons:

- normalize/hash memory bullets before appending
- avoid semantically duplicated facts
- track `last_verified` or `source_session`
- mark stale facts instead of silently preserving old assumptions forever

### 5. Add undo/edit affordance

Once memory updates are visible, users need a correction path.

Likely future tools:

- `memory_undo last`
- `memory_edit`
- `memory_status recent_updates`

This should reuse the same deterministic memory write lane, not create a separate hidden editor.

### 6. Centralize automatic refresh ownership

Automatic refresh should eventually have one owner-run completion lane.

Recommended shape:

- Runner records the session/result.
- InboundWorker owns "final reply delivered" and then schedules refresh.
- MemoryUpdater owns refresh serialization and notice delivery.

This avoids duplicate enqueue semantics and makes notice ordering easier to reason about.

## Review Guidance

Reject changes that:

- replace `MEMORY.md` with a new DB/vector store as part of the cost/visibility work
- make memory refresh read config directly instead of using Runtime/Config accessors
- send memory notices for noop refreshes
- send memory notices from cron/follow-up/subagent/internal contexts
- expose full memory diffs or raw conversation as user-visible notice text
- add per-channel memory isolation without a separate design
- tune trigger frequency before memory updates are observable

The current memory system works because the core truth sources are boring and inspectable. Keep that property while improving cost and trust.
