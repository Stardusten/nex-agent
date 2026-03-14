# Context Identity Boundary Hardening

## TL;DR
> **Summary**: Define and enforce a strict boundary contract so `identity`, `SOUL`, `USER`, `MEMORY`, bootstrap files, and evolution tools can coexist without prompt conflicts or silent user-file mutation.
> **Deliverables**:
> - Canonical layer contract for identity/soul/user/memory/bootstrap content
> - Runtime enforcement in prompt composition and update tools
> - Forward-safe onboarding templates for new workspaces
> - Diagnostics and regression tests covering conflict handling and non-overwrite guarantees
> **Effort**: Medium
> **Parallel**: YES - 2 waves
> **Critical Path**: Task 1 -> Task 2 -> Task 3 -> Task 6

## Context
### Original Request
Define a clear specification for this project's `identity / soul / user` boundaries and ensure the code can implement it without conflicts.

### Interview Summary
- Context assembly currently duplicates identity and operating rules across `ContextBuilder` and bootstrap files.
- Existing workspace files are user-owned inputs and must not be silently rewritten as the primary fix.
- `SOUL.md` should not replace the agent's base identity.
- `vendors/nanobot` is the comparison baseline: fixed code identity, bootstrap overlays, onboarding creates missing files only.
- Default decisions applied for planning: diagnostics on read/compose, rejection on invalid new writes, preserve workspace-global `USER.md`/`MEMORY.md`, and do not introduce per-session identity partitioning in this change.

### Metis Review (gaps addressed)
- Added first-class diagnostics to the scope; do not rely on ordering or a final identity guard alone.
- Added explicit `soul_update` semantics rather than leaving it as unchecked full-document overwrite.
- Added non-overwrite onboarding behavior and characterization tests as required acceptance criteria.
- Scoped out broader session/memory redesign to avoid architecture sprawl.

## Work Objectives
### Core Objective
Make identity precedence and layer ownership explicit in code so the runtime always treats `Nex Agent` as authoritative identity, interprets `SOUL.md` as persona/value/style overlay only, keeps `USER.md` as user profile, and prevents future conflicts from bootstrap files or evolution tools.

### Deliverables
- A canonical boundary contract encoded in prompt composition behavior
- Guarded `soul_update` and `user_update` semantics aligned with the contract
- Updated onboarding templates for future workspaces that no longer encode conflicting guidance
- Diagnostics surface for layer violations discovered during load or write
- Regression tests for prompt precedence, diagnostics, tool semantics, and onboarding preservation

### Definition of Done (verifiable conditions with commands)
- `mix test test/nex/agent/context_builder_test.exs` passes with new prompt-precedence and diagnostics cases.
- `mix test test/nex/agent/user_update_test.exs` passes with updated boundary semantics.
- `mix test test/nex/agent/onboarding_migration_test.exs` passes with non-overwrite coverage for user-owned files.
- `mix test test/nex/agent/runner_evolution_test.exs` passes if diagnostics/evolution nudges interact with the changed layer contract.
- `mix test` passes for all newly added targeted suites.

### Must Have
- One authoritative code-owned identity source.
- A documented and test-enforced contract for allowed/forbidden content per layer.
- Diagnostics for out-of-layer content discovered in bootstrap files.
- No silent rewriting of existing user `SOUL.md`, `USER.md`, or customized bootstrap content.
- Backward-tolerant behavior for existing workspaces.

### Must NOT Have (guardrails, AI slop patterns, scope boundaries)
- No auto-migration that rewrites existing user markdown without explicit action.
- No prompt-architecture redesign beyond layer precedence, diagnostics, and tool semantics.
- No per-session user/profile partitioning in this change.
- No reliance on prompt order alone as the only enforcement mechanism.
- No vague “persona cleanup” without executable tests.

## Verification Strategy
> ZERO HUMAN INTERVENTION — all verification is agent-executed.
- Test decision: tests-after using ExUnit + targeted regression coverage.
- QA policy: Every task includes agent-executed happy-path and failure/edge scenarios.
- Evidence: `.sisyphus/evidence/task-{N}-{slug}.{ext}`

## Execution Strategy
### Parallel Execution Waves
> Target: 5-8 tasks per wave. <3 per wave (except final) = under-splitting.
> Extract shared dependencies as Wave-1 tasks for max parallelism.

Wave 1: boundary contract, characterization tests, diagnostics design, update-tool semantics
Wave 2: prompt composition implementation, onboarding/template alignment, regression consolidation, docs/changelog if needed

### Dependency Matrix (full, all tasks)
- Task 1 blocks Tasks 2-8
- Task 2 blocks Tasks 5-8
- Task 3 blocks Tasks 5-7
- Task 4 blocks Task 6
- Task 5 depends on Tasks 1-3
- Task 6 depends on Tasks 1, 3, 4, 5
- Task 7 depends on Tasks 1, 2, 5, 6
- Task 8 depends on Tasks 5-7

### Agent Dispatch Summary (wave → task count → categories)
- Wave 1 -> 4 tasks -> deep / unspecified-high / quick
- Wave 2 -> 4 tasks -> deep / quick / writing

## TODOs
> Implementation + Test = ONE task. Never separate.
> EVERY task MUST have: Agent Profile + Parallelization + QA Scenarios.

- [x] 1. Define the canonical layer contract and conflict policy

  **What to do**: Create a code-adjacent specification in implementation notes/tests that defines, for each layer, purpose, owner, allowed content, forbidden content, precedence, mutability, and diagnostics behavior. The contract must explicitly state: code-owned identity is authoritative; `SOUL.md` is persona/value/style only; `USER.md` is user profile and collaboration preferences only; `MEMORY.md` is durable environment/project/workflow facts only; `AGENTS.md` is system-level instructions but cannot redefine identity; `TOOLS.md` is tool usage reference only.
  **Must NOT do**: Do not redesign memory/session scope, do not auto-rewrite existing workspace files, and do not leave any layer without explicit forbidden-content rules.

  **Recommended Agent Profile**:
  - Category: `deep` — Reason: this task defines the authoritative contract every later change depends on.
  - Skills: `[]` — no external skill is required.
  - Omitted: `['writing']` — the task is policy design tied to code paths, not prose polish alone.

  **Parallelization**: Can Parallel: NO | Wave 1 | Blocks: [2, 3, 4, 5, 6, 7, 8] | Blocked By: []

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `lib/nex/agent/context_builder.ex:17` — current system prompt assembly order and content sources.
  - Pattern: `lib/nex/agent/context_builder.ex:117` — bootstrap file loading behavior.
  - Pattern: `lib/nex/agent/tool/soul_update.ex:27` — current unrestricted SOUL overwrite.
  - Pattern: `lib/nex/agent/tool/user_update.ex:49` — structured append/set model for USER updates.
  - Pattern: `lib/nex/agent/tool/memory_write.ex:10` — current layer descriptions used by the model.
  - Pattern: `lib/nex/agent/onboarding.ex:225` — current AGENTS/SOUL/USER/TOOLS templates encode old boundaries.
  - External: `vendors/nanobot/nanobot/agent/context.py:27` — reference baseline for fixed code identity plus bootstrap overlays.
  - External: `vendors/nanobot/nanobot/utils/helpers.py:173` — reference baseline for non-overwriting onboarding sync.

  **Acceptance Criteria** (agent-executable only):
  - [ ] The implementation notes/tests encode one unambiguous allowed/forbidden matrix for `identity`, `AGENTS`, `SOUL`, `USER`, `TOOLS`, and `MEMORY`.
  - [ ] The contract includes exact defaults for conflict handling on read/compose and on write.
  - [ ] The contract is reflected in at least one characterization test name or test fixture comment so it becomes executable guidance, not just tribal knowledge.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```text
  Scenario: Contract matrix exists and is executable
    Tool: Bash
    Steps: run `mix test test/nex/agent/context_builder_test.exs`
    Expected: target test file includes new contract-oriented cases and exits with code 0 after implementation
    Evidence: .sisyphus/evidence/task-1-layer-contract.txt

  Scenario: Forbidden content is explicitly covered
    Tool: Bash
    Steps: run `grep -n "SOUL.*identity\|USER.*identity\|MEMORY.*persona" test/nex/agent/context_builder_test.exs test/nex/agent/user_update_test.exs`
    Expected: grep finds explicit cases for out-of-layer content handling
    Evidence: .sisyphus/evidence/task-1-layer-contract-error.txt
  ```

  **Commit**: YES | Message: `test(context): codify identity and layer contract` | Files: [`test/nex/agent/context_builder_test.exs`, `test/nex/agent/user_update_test.exs`, optional new test helper]

- [x] 2. Add characterization tests for prompt precedence and conflict diagnostics

  **What to do**: Build temp-workspace ExUnit coverage that composes prompts from conflicting bootstrap inputs and asserts final precedence. Include cases where `SOUL.md` contains identity replacement text, `AGENTS.md` declares outdated capability models, and `USER.md` contains persona-like directives. Tests must verify the authoritative identity remains `Nex Agent`, conflicting content is downgraded/diagnosed, and tolerated files are still loaded without overwrite.
  **Must NOT do**: Do not implement the runtime fix before the failing tests are in place; do not rely on visual prompt inspection.

  **Recommended Agent Profile**:
  - Category: `unspecified-high` — Reason: non-trivial ExUnit characterization with temp workspace fixtures.
  - Skills: `[]` — repo-native test patterns are sufficient.
  - Omitted: `['playwright']` — no browser work involved.

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: [5, 7, 8] | Blocked By: [1]

  **References** (executor has NO interview context — be exhaustive):
  - Test: `test/nex/agent/context_builder_test.exs:21` — existing prompt builder tests and temp-workspace setup style.
  - Test: `test/nex/agent/profile_path_guard_test.exs:21` — workspace path and file boundary test style.
  - Pattern: `lib/nex/agent/context_builder.ex:217` — current `build_messages/6` behavior and one-system-message invariant.
  - Pattern: `/Users/fenix/.nex/agent/workspace/SOUL.md:3` — real-world example of identity-conflicting soul content.
  - Pattern: `/Users/fenix/.nex/agent/workspace/AGENTS.md:5` — outdated “All capabilities are Skills” text to model in fixtures.
  - Pattern: `vendors/nanobot/nanobot/agent/context.py:109` — bootstrap files are loaded as raw content; useful baseline for fixture design.

  **Acceptance Criteria** (agent-executable only):
  - [ ] New tests fail on the pre-fix code and pass after implementation.
  - [ ] Tests assert that conflicting `SOUL.md` identity text does not become authoritative in the final system prompt.
  - [ ] Tests assert that diagnostics are emitted for out-of-layer content with stable expected text/shape.
  - [ ] Tests assert existing user files are read, not rewritten, during prompt composition.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```text
  Scenario: Conflicting SOUL identity is tolerated but non-authoritative
    Tool: Bash
    Steps: run `mix test test/nex/agent/context_builder_test.exs --only prompt_precedence`
    Expected: test exits 0 and asserts final prompt still contains `You are Nex Agent` as authoritative identity
    Evidence: .sisyphus/evidence/task-2-prompt-precedence.txt

  Scenario: Out-of-layer content produces diagnostics
    Tool: Bash
    Steps: run `mix test test/nex/agent/context_builder_test.exs --only boundary_diagnostics`
    Expected: test exits 0 and asserts a stable warning/diagnostic for invalid identity content in `SOUL.md` or persona content in `USER.md`
    Evidence: .sisyphus/evidence/task-2-prompt-precedence-error.txt
  ```

  **Commit**: YES | Message: `test(context): characterize bootstrap conflicts` | Files: [`test/nex/agent/context_builder_test.exs`, optional new fixture helper]

- [x] 3. Design and implement a boundary diagnostics surface

  **What to do**: Introduce a concrete diagnostics mechanism used by prompt composition and mutation tools. Decide the representation (`{:ok, prompt, diagnostics}` helper, structured warning list in metadata, log entries with stable codes, or an internal validator module) and ensure it can detect at minimum: identity declarations in `SOUL.md`, persona instructions in `MEMORY.md`, user-profile data in `SOUL.md`, and outdated capability model claims in `AGENTS.md`. Diagnostics must be stable enough for tests and future user-facing lint/report tooling.
  **Must NOT do**: Do not bury diagnostics as ad-hoc log strings only; do not make warnings non-deterministic.

  **Recommended Agent Profile**:
  - Category: `deep` — Reason: this defines the enforcement mechanism shared by composition and write tools.
  - Skills: `[]` — internal architecture task.
  - Omitted: `['writing']` — behavior contract is more important than docs here.

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: [5, 6, 7, 8] | Blocked By: [1]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `lib/nex/agent/context_builder.ex:21` — current assembly pipeline and natural integration point.
  - Pattern: `lib/nex/agent/runner.ex:137` — runtime system message merge path if diagnostics need to influence nudges or metadata.
  - Pattern: `lib/nex/agent/tool/soul_update.ex:27` — write path that must reuse diagnostics/validation.
  - Pattern: `lib/nex/agent/tool/user_update.ex:55` — write path that can enforce layer-specific validation.
  - Pattern: `vendors/hermes-agent/agent/prompt_builder.py:20` — useful reference for prompt-context scanning with stable threat categories.

  **Acceptance Criteria** (agent-executable only):
  - [ ] There is one reusable validation/diagnostics path rather than duplicated regex logic across multiple modules.
  - [ ] Diagnostics expose stable category identifiers or stable exact messages suitable for ExUnit assertions.
  - [ ] At least four invalid-content categories are covered by tests.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```text
  Scenario: Prompt composition emits stable diagnostics
    Tool: Bash
    Steps: run `mix test test/nex/agent/context_builder_test.exs --only boundary_diagnostics`
    Expected: diagnostics include stable category keys/text for invalid layer content and exit code is 0
    Evidence: .sisyphus/evidence/task-3-boundary-diagnostics.txt

  Scenario: Invalid writes are rejected by shared validator
    Tool: Bash
    Steps: run `mix test test/nex/agent/user_update_test.exs --only invalid_layer_write`
    Expected: test exits 0 and asserts write rejection with a stable reason
    Evidence: .sisyphus/evidence/task-3-boundary-diagnostics-error.txt
  ```

  **Commit**: YES | Message: `feat(context): add layer diagnostics primitives` | Files: [new validator module, `lib/nex/agent/context_builder.ex`, related tests]

- [x] 4. Redefine `soul_update` and `user_update` semantics around the new contract

  **What to do**: Change tool semantics so `soul_update` can no longer act as unrestricted identity replacement. Decide the exact allowed write model: validated full-document replacement with forbidden identity lines removed/rejected, or structured append/set behavior similar to `user_update`. Align `user_update` validation with the new boundary contract so it rejects persona/identity attempts while keeping profile-friendly append/set ergonomics. Update tool descriptions so the model sees the same contract the runtime enforces.
  **Must NOT do**: Do not keep `soul_update` as raw `File.write/2` with no validation, and do not leave tool descriptions inconsistent with runtime behavior.

  **Recommended Agent Profile**:
  - Category: `unspecified-high` — Reason: tool semantics and UX need careful alignment with tests.
  - Skills: `[]` — repo-native code patterns are enough.
  - Omitted: `['writing']` — copy updates are secondary to enforcement logic.

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: [6, 8] | Blocked By: [1]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `lib/nex/agent/tool/soul_update.ex:8` — current tool description and schema.
  - Pattern: `lib/nex/agent/tool/soul_update.ex:27` — current dangerous full overwrite path.
  - Pattern: `lib/nex/agent/tool/user_update.ex:10` — current layer-specific description.
  - Pattern: `lib/nex/agent/tool/user_update.ex:74` — current append/upsert behavior to preserve where valid.
  - Pattern: `lib/nex/agent/tool/memory_write.ex:10` — current layer contract language exposed to the model.
  - Test: `test/nex/agent/user_update_test.exs:23` — existing update-tool test style.

  **Acceptance Criteria** (agent-executable only):
  - [ ] `soul_update` rejects identity-replacement content with a stable, tested error.
  - [ ] `user_update` rejects persona/identity content but still supports valid append/set profile updates.
  - [ ] Tool `description/0` text matches actual allowed behavior after the change.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```text
  Scenario: Valid user profile update still works
    Tool: Bash
    Steps: run `mix test test/nex/agent/user_update_test.exs --only valid_profile_append`
    Expected: test exits 0 and asserts USER.md receives profile-safe content
    Evidence: .sisyphus/evidence/task-4-update-tool-semantics.txt

  Scenario: Invalid identity replacement is rejected
    Tool: Bash
    Steps: run `mix test test/nex/agent/user_update_test.exs --only invalid_layer_write && mix test test/nex/agent/soul_update_validation_test.exs`
    Expected: tests exit 0 and assert `I am Claude`-style content is rejected for SOUL/USER paths according to the new contract
    Evidence: .sisyphus/evidence/task-4-update-tool-semantics-error.txt
  ```

  **Commit**: YES | Message: `feat(evolution): guard soul and user updates` | Files: [`lib/nex/agent/tool/soul_update.ex`, `lib/nex/agent/tool/user_update.ex`, `lib/nex/agent/tool/memory_write.ex`, `test/nex/agent/user_update_test.exs`, new `test/nex/agent/soul_update_validation_test.exs`]

- [x] 5. Refactor `ContextBuilder` so precedence and boundaries are enforced in composition

  **What to do**: Implement the contract in the prompt builder. Collapse duplicated identity/rule blocks into one authoritative code-owned identity section, interpret bootstrap files by layer rather than blindly trusting all content equally, and make sure conflicting layer content is diagnosed instead of silently competing. Keep the one-system-message invariant and preserve runtime metadata/user message behavior unless a change is required by the contract.
  **Must NOT do**: Do not silently drop user-owned files without diagnostics, do not add multiple system messages, and do not expand into full token-budget redesign.

  **Recommended Agent Profile**:
  - Category: `deep` — Reason: this is the core runtime change with the highest blast radius.
  - Skills: `[]` — architecture change within repo conventions.
  - Omitted: `['vercel-react-best-practices']` — unrelated stack.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [6, 7, 8] | Blocked By: [1, 2, 3]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `lib/nex/agent/context_builder.ex:21` — current assembly pipeline and duplication points.
  - Pattern: `lib/nex/agent/context_builder.ex:44` — runtime guidance currently duplicates rules in `AGENTS.md`.
  - Pattern: `lib/nex/agent/context_builder.ex:98` — current evolution guidance that overlaps with bootstrap content.
  - Pattern: `lib/nex/agent/context_builder.ex:139` — current skills injection path with always-on content + summary duplication.
  - Pattern: `lib/nex/agent/context_builder.ex:217` — message assembly and system prompt merge.
  - Pattern: `lib/nex/agent/system_prompt.ex:20` — wrapper entrypoint that should preserve behavior.
  - Test: `test/nex/agent/context_builder_test.exs:21` — existing regression base.

  **Acceptance Criteria** (agent-executable only):
  - [ ] Final system prompt has one authoritative identity source and no duplicate identity sections.
  - [ ] Bootstrap conflicts are handled according to the contract with diagnostics.
  - [ ] Existing valid `SOUL.md` persona/style content still influences the prompt.
  - [ ] The one-system-message invariant remains true.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```text
  Scenario: Authoritative identity survives conflicting bootstrap files
    Tool: Bash
    Steps: run `mix test test/nex/agent/context_builder_test.exs --only prompt_precedence`
    Expected: test exits 0 and asserts final prompt contains one authoritative Nex identity block while preserving valid persona overlay text
    Evidence: .sisyphus/evidence/task-5-contextbuilder-precedence.txt

  Scenario: Duplicate identity blocks are removed
    Tool: Bash
    Steps: run `mix test test/nex/agent/context_builder_test.exs --only no_duplicate_identity`
    Expected: test exits 0 and asserts only one identity anchor remains in the rendered prompt
    Evidence: .sisyphus/evidence/task-5-contextbuilder-precedence-error.txt
  ```

  **Commit**: YES | Message: `refactor(context): enforce identity and layer precedence` | Files: [`lib/nex/agent/context_builder.ex`, `lib/nex/agent/system_prompt.ex`, related tests]

- [x] 6. Align onboarding and template generation with the new ownership model

  **What to do**: Update onboarding templates so future workspaces no longer encode the old conflicts. `AGENTS.md` should no longer restate code-owned identity or outdated capability models. `SOUL.md` should describe persona/values/style only. `USER.md`, `TOOLS.md`, and memory templates should match the new contract. Preserve the current ownership rule: future template refreshes may update managed blocks where intended, but user-owned files such as customized `SOUL.md`/`USER.md` must not be silently rewritten.
  **Must NOT do**: Do not change existing user workspaces as a migration side effect, and do not leave template text contradicting runtime enforcement.

  **Recommended Agent Profile**:
  - Category: `writing` — Reason: template semantics need precise wording plus implementation-safe alignment.
  - Skills: `[]` — straightforward repo templating task.
  - Omitted: `['deep']` — the hard architectural decisions should already be settled by prior tasks.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [7, 8] | Blocked By: [1, 3, 4, 5]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `lib/nex/agent/onboarding.ex:225` — current AGENTS template duplicates runtime rules and identity.
  - Pattern: `lib/nex/agent/onboarding.ex:343` — current SOUL template mixes identity and hot-reload rules.
  - Pattern: `lib/nex/agent/onboarding.ex:371` — USER template baseline.
  - Pattern: `lib/nex/agent/onboarding.ex:403` — MEMORY template baseline.
  - External: `vendors/nanobot/nanobot/templates/SOUL.md:1` — reference for concise persona template.
  - External: `vendors/nanobot/nanobot/utils/helpers.py:173` — reference for create-missing-files-only behavior.

  **Acceptance Criteria** (agent-executable only):
  - [ ] New template text does not encode identity replacement in `SOUL.md` or the obsolete “all capabilities are skills” model.
  - [ ] Onboarding tests prove existing customized user files are preserved.
  - [ ] Forward-created workspaces receive templates consistent with runtime layer enforcement.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```text
  Scenario: New workspace gets conflict-free templates
    Tool: Bash
    Steps: run `mix test test/nex/agent/onboarding_migration_test.exs --only new_workspace_templates`
    Expected: test exits 0 and asserts generated AGENTS/SOUL/USER/TOOLS templates follow the new contract
    Evidence: .sisyphus/evidence/task-6-onboarding-templates.txt

  Scenario: Existing customized files are not overwritten
    Tool: Bash
    Steps: run `mix test test/nex/agent/onboarding_migration_test.exs --only preserve_existing_files`
    Expected: test exits 0 and asserts customized `SOUL.md`/`USER.md` content remains untouched after onboarding/template sync
    Evidence: .sisyphus/evidence/task-6-onboarding-templates-error.txt
  ```

  **Commit**: YES | Message: `docs(onboarding): align templates with layer contract` | Files: [`lib/nex/agent/onboarding.ex`, `test/nex/agent/onboarding_migration_test.exs`]

- [x] 7. Add regression coverage for workspace-global sharing and tolerated legacy content

  **What to do**: Add tests that make the plan's defaults explicit: `USER.md` and `MEMORY.md` remain workspace-global; legacy files with old identity text are tolerated but diagnosed; prompt assembly still works when some bootstrap files are missing; and onboarding plus composition together do not introduce silent mutations. Cover at least two sessions sharing one workspace to prove the current non-goal is deliberate and documented.
  **Must NOT do**: Do not accidentally redesign session scoping under the guise of test setup, and do not leave legacy behavior implicit.

  **Recommended Agent Profile**:
  - Category: `unspecified-high` — Reason: regression matrix spans multiple modules and fixtures.
  - Skills: `[]` — ExUnit and temp workspace patterns are enough.
  - Omitted: `['writing']` — this is behavior-locking work, not docs-first.

  **Parallelization**: Can Parallel: YES | Wave 2 | Blocks: [8] | Blocked By: [2, 3, 5, 6]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `lib/nex/agent/session.ex:29` — session key model (`channel:chat_id`).
  - Pattern: `lib/nex/agent/memory.ex:71` — memory context load behavior.
  - Pattern: `lib/nex/agent/runner.ex:1031` — consolidation reads `USER.md` and `MEMORY.md` together.
  - Pattern: `/Users/fenix/.nex/agent/workspace/USER.md:7` — example workspace-global profile content.
  - Pattern: `/Users/fenix/.nex/agent/workspace/memory/MEMORY.md:29` — example workspace-global project facts.
  - Test: `test/nex/agent/runner_evolution_test.exs:37` — existing evolution-related test style.

  **Acceptance Criteria** (agent-executable only):
  - [ ] Tests explicitly document and verify workspace-global sharing for `USER.md` and `MEMORY.md`.
  - [ ] Legacy conflicting files are tolerated with diagnostics, not silent mutation.
  - [ ] Missing bootstrap files do not break prompt assembly or diagnostics.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```text
  Scenario: Workspace-global sharing is explicit and stable
    Tool: Bash
    Steps: run `mix test test/nex/agent/runner_evolution_test.exs --only workspace_global_profile`
    Expected: test exits 0 and asserts two session keys share the same USER/MEMORY workspace view by design
    Evidence: .sisyphus/evidence/task-7-legacy-and-sharing.txt

  Scenario: Legacy conflicting files are tolerated without mutation
    Tool: Bash
    Steps: run `mix test test/nex/agent/context_builder_test.exs --only legacy_conflict_tolerance`
    Expected: test exits 0 and asserts diagnostics are emitted while files remain unchanged
    Evidence: .sisyphus/evidence/task-7-legacy-and-sharing-error.txt
  ```

  **Commit**: YES | Message: `test(context): lock legacy tolerance and sharing semantics` | Files: [`test/nex/agent/context_builder_test.exs`, `test/nex/agent/runner_evolution_test.exs`, optional new regression test file]

- [x] 8. Finalize model-facing descriptions and release notes for the new contract

  **What to do**: Sweep model-visible descriptions and developer-facing notes so the runtime contract is coherent everywhere the model reads it. Update tool descriptions (`soul_update`, `user_update`, `memory_write`) and any prompt-facing wording left inconsistent after Tasks 5-7. Add changelog and implementation notes only if needed to explain the boundary change to maintainers.
  **Must NOT do**: Do not introduce new behavioral semantics at this stage; this task is alignment and cleanup only.

  **Recommended Agent Profile**:
  - Category: `writing` — Reason: copy-level consistency after behavior is settled.
  - Skills: `[]` — internal wording and notes only.
  - Omitted: `['deep']` — semantics should already be locked.

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [] | Blocked By: [2, 3, 4, 5, 6, 7]

  **References** (executor has NO interview context — be exhaustive):
  - Pattern: `lib/nex/agent/tool/soul_update.ex:8` — model-visible SOUL semantics.
  - Pattern: `lib/nex/agent/tool/user_update.ex:10` — model-visible USER semantics.
  - Pattern: `lib/nex/agent/tool/memory_write.ex:10` — model-visible MEMORY semantics.
  - Pattern: `CHANGELOG.md:1` — release note location if change should be recorded.
  - Pattern: `.sisyphus/plans/context-identity-boundaries.md:31` — canonical objective and deliverables to keep wording aligned.

  **Acceptance Criteria** (agent-executable only):
  - [ ] All model-visible layer descriptions agree with the enforced contract.
  - [ ] No remaining prompt-facing text claims `SOUL` owns base identity or that all capabilities are skills.
  - [ ] Release notes or implementation notes summarize the behavior change if project policy requires it.

  **QA Scenarios** (MANDATORY — task incomplete without these):
  ```text
  Scenario: Prompt-facing copy is internally consistent
    Tool: Bash
    Steps: run `grep -n "identity and principle\|all capabilities are skills\|SOUL: identity" lib/nex/agent test/nex/agent CHANGELOG.md`
    Expected: grep returns only intentionally updated wording or no matches for obsolete phrases
    Evidence: .sisyphus/evidence/task-8-copy-alignment.txt

  Scenario: Final targeted regressions still pass after wording cleanup
    Tool: Bash
    Steps: run `mix test test/nex/agent/context_builder_test.exs test/nex/agent/user_update_test.exs test/nex/agent/onboarding_migration_test.exs test/nex/agent/runner_evolution_test.exs test/nex/agent/soul_update_validation_test.exs`
    Expected: all targeted suites exit with code 0
    Evidence: .sisyphus/evidence/task-8-copy-alignment-error.txt
  ```

  **Commit**: YES | Message: `docs(context): align layer wording with runtime contract` | Files: [`lib/nex/agent/tool/soul_update.ex`, `lib/nex/agent/tool/user_update.ex`, `lib/nex/agent/tool/memory_write.ex`, optional `CHANGELOG.md`]

## Final Verification Wave (4 parallel agents, ALL must APPROVE)
- [x] F1. Plan Compliance Audit — oracle
- [x] F2. Code Quality Review — unspecified-high
- [x] F3. Real Manual QA — unspecified-high (+ playwright if UI)
- [x] F4. Scope Fidelity Check — deep

  **F1 QA Scenario**
  ```text
  Tool: Bash
  Steps: run `mix test test/nex/agent/context_builder_test.exs test/nex/agent/user_update_test.exs test/nex/agent/onboarding_migration_test.exs test/nex/agent/runner_evolution_test.exs test/nex/agent/soul_update_validation_test.exs`
  Expected: all targeted suites exit with code 0 and no skipped contract-critical tests remain unexplained
  Evidence: .sisyphus/evidence/f1-plan-compliance.txt
  ```

  **F2 QA Scenario**
  ```text
  Tool: Bash
  Steps: run `mix compile && mix credo --strict`
  Expected: compile succeeds and Credo exits with code 0 with no new style or consistency regressions in touched modules/tests
  Evidence: .sisyphus/evidence/f2-code-quality.txt
  ```

  **F3 QA Scenario**
  ```text
  Tool: Bash
  Steps: run `mix test test/nex/agent/context_builder_test.exs --only prompt_precedence && mix test test/nex/agent/context_builder_test.exs --only legacy_conflict_tolerance && mix test test/nex/agent/onboarding_migration_test.exs --only preserve_existing_files`
  Expected: happy-path and edge-path checks both pass, demonstrating real runtime tolerance of conflicting files without silent mutation
  Evidence: .sisyphus/evidence/f3-manual-qa.txt
  ```

  **F4 QA Scenario**
  ```text
  Tool: Bash
  Steps: run `grep -n "per-session\|session partition\|silent rewrite\|auto-migration" .sisyphus/plans/context-identity-boundaries.md && mix test test/nex/agent/runner_evolution_test.exs --only workspace_global_profile`
  Expected: plan still reflects the intended scope boundaries and the regression confirms workspace-global sharing remains explicit rather than accidentally redesigned
  Evidence: .sisyphus/evidence/f4-scope-fidelity.txt
  ```

## Commit Strategy
- Commit 1: characterization tests for current prompt conflicts and desired contract.
- Commit 2: diagnostics and boundary primitives used by prompt composition and tools.
- Commit 3: `ContextBuilder` enforcement and bootstrap interpretation changes.
- Commit 4: `soul_update` / `user_update` guarded semantics.
- Commit 5: onboarding/template alignment and regression coverage.

## Success Criteria
- Conflicting identity text in user-owned files no longer overrides base identity.
- `SOUL.md`, `USER.md`, and `MEMORY.md` each have one clear runtime role with tests proving the boundary.
- Existing workspaces remain readable and do not get silently rewritten.
- New workspaces get templates that do not encode the old conflicts.
- Evolution tools can no longer introduce cross-layer violations unnoticed.
