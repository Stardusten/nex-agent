# AGENTS

Load the repo-local skills before you start changing code when they match the task.

## Collaboration Preferences

- Do not end responses with soft follow-up prompts like “if you want” / “if you’d like” / “if you愿意”.
- Distinguish clearly between a working draft for internal thinking and a polished document that can be shared directly. Do not leave meta-writing scaffolding in shareable docs.
- During a phase/stage refactor, do not add compatibility shims just to keep an intermediate state compiling.
- For repo-internal APIs, prefer deleting the old API first and using compile errors to drive the migration so every affected call site gets updated deliberately.
- Only keep or add compatibility logic when the task explicitly requires preserving an external/public contract or a user-facing behavior across the migration.

## Browser Automation

Use `agent-browser` for web automation. Run `agent-browser --help` for all commands.

Core workflow:

1. `agent-browser open <url>` - Navigate to page
2. `agent-browser snapshot -i` - Get interactive elements with refs (`@e1`, `@e2`)
3. `agent-browser click @e1` / `agent-browser fill @e2 "text"` - Interact using refs
4. Re-snapshot after page changes

For manual GitHub issue work in this repository:

1. Use `issue_to_pr` when an issue is already selected and the goal is to move it to a verified pull request.
2. Use `pr_open` only after verification has run and the change is ready to commit, push, and open as a PR.
3. Use `issue_sync` to leave concise blocker or handoff updates on the issue.

Keep changes small, run the narrowest useful verification first, and do not open a PR until the work is verified.

## Git Workflow

This repository is developed directly on `main`.

- Do not create or switch to a feature/topic branch unless the user explicitly asks for a branch or PR workflow.
- If the user asks to commit or push without naming a branch, do that work on `main`.
- Treat an unprompted branch switch in this repo as a mistake to avoid repeating.

## Known Test Baseline

- On 2026-04-16, the memory/consolidation failures below were reproduced on phase1-before baseline `cb06f0fbe14901d68b27187c288cf19f5b40f2e5` (`2311c99^`) after stashing phase3 work.
- Command used on that baseline: `mix test test/nex/agent/memory_rebuild_test.exs test/nex/agent/memory_updater_test.exs test/nex/agent/memory_consolidate_test.exs test/nex/agent/runner_evolution_test.exs`
- Baseline result: 24 tests, 6 failures.
- Failing areas: `MemoryRebuildTest` prompt memory block regex failures, `MemoryUpdaterTest` same prompt memory block failure, `MemoryConsolidateTest` `already_running` wait timeout, and `RunnerEvolutionTest` async memory consolidation history not updated.
- Do not treat those specific failures as phase3 streaming regressions unless they reproduce differently from this baseline or a task explicitly targets memory/consolidation stability.

## LLM API Conventions

This project uses Anthropic-compatible APIs (including kimi etc.). When constructing LLM request options:

- **tool_choice** must use Anthropic format: `%{type: "tool", name: "tool_name"}`
- Do NOT use OpenAI format: `%{type: "function", function: %{name: "tool_name"}}`
- Allowed `type` values for Anthropic: `auto`, `any`, `tool`, `none`

## Documentation Layout

All project docs live under `docs/dev/`.

- `docs/dev/findings/`: design conclusions, tradeoff notes, investigation output, and non-execution writeups
- `docs/dev/progress/`: execution progress and status tracking
- `docs/dev/task-plan/`: executor-facing implementation plans

Expected anchor files:

- `docs/dev/findings/index.md`
- `docs/dev/progress/index.md`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/task-plan/index.md`

`docs/dev/progress/CURRENT.md` is the current mainline status file. It should let a later executor understand the active workstream quickly.

Daily progress logs live under `docs/dev/progress/YYYY-MM-DD.md`.

## Task Plan Rules

Files under `docs/dev/task-plan/phase*.md` are execution documents for implementers, not design essays.

Default goal:

- After reading the plan, a later executor should know what to change first, where to change it, what counts as done, and how to verify it.

Required rules:

1. Write execution first.
   - Keep scope notes only when they are necessary for implementation.
   - Move long-form motivation, architecture discussion, and tradeoff analysis to `docs/dev/findings/`.
2. Organize each phase by `Stage`, not by prose themes.
   - The reader should be able to see stage order, dependencies, and current stage immediately.
3. Every stage must include all of the following sections:
   - `前置检查`
   - `这一步改哪里`
   - `这一步要做`
   - `实施注意事项`
   - `本 stage 验收`
   - `本 stage 验证`
4. `这一步改哪里` must name concrete files, modules, key functions, and important structs whenever they are already known.
   - Avoid vague wording like “add parser support” or “wire indexing”.
5. If a struct shape, operation shape, status contract, or other critical boundary is already decided, write it down directly in the plan.
   - Use the smallest concrete shape needed to prevent drift during implementation.
6. If a critical boundary is still undecided, do not hide that uncertainty inside the plan.
   - Stop and record the decision in `docs/dev/findings/` first, or confirm it with the user.
7. Split stages by delivery order and validation boundaries, not by presentation style.
   - A valid stage must be independently landable, independently reviewable, and keep the repo verifiable.
8. Acceptance criteria must follow the real active path, not a cold path, fake path, or future path.
   - Do not gate a stage on machinery that is not yet the real production path.
9. Each stage must end in a verifiable repository state.
   - Do not plan to “make tests red now and fix later”.
10. Plans must answer these execution questions directly:
   - What must be checked before starting this stage?
   - Which files/functions should be edited first?
   - Which scope expansions are explicitly out of bounds?
   - What observable result means the stage passed?
   - Which command or smoke flow verifies it?
11. For stages that freeze core structs, contracts, or pipeline boundaries, do not describe them only in prose.
   - Include concrete code or pseudocode for the decided shape.
   - Prefer exact struct field names, function signatures, map shapes, and event/action tuples.
   - If a later executor could plausibly “fill in the blanks” in multiple incompatible ways, the plan is not frozen enough.
12. When a stage is intended to be directly executable, the plan should bias toward implementation detail over narrative summary.
   - Include the exact modules, public functions, helper names, and data flow transitions expected in that stage.
   - Use the smallest concrete code snippet needed to prevent drift.
13. Do not turn a phase file into a full onboarding document.
   - Keep only the minimum background needed for implementation.
   - Point readers back to `CURRENT.md`, `task-plan/index.md`, `findings/index.md`, and `progress/index.md` for context recovery.
14. A document that only gives direction, without stage structure, implementation steps, acceptance, and verification, is a design note, not a valid execution plan.

Recommended phase template:

1. `当前状态`
2. `完成后必须达到的结果`
3. `开工前必须先看的代码路径`
4. `固定边界 / 已冻结的数据结构与 contract`
5. `执行顺序 / stage 依赖`
6. `Stage N`
   - `前置检查`
   - `这一步改哪里`
   - `这一步要做`
   - `实施注意事项`
   - `本 stage 验收`
   - `本 stage 验证`
7. `Review Fail 条件`
