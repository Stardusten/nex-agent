# Fix Runner Stringification Crash And Tool Dedupe

## TL;DR
> **Summary**: Stop the `io.chardata_to_string` crash by hardening Runner stringification paths so non-binary tool args, tool results, and model content are rendered safely before any `String.*` call or outbound publish. Also dedupe merged tool definitions before submitting them to the LLM so the six-layer evolution path no longer surfaces duplicate tool names.
> **Deliverables**:
> - Runner regression tests for non-binary args, results, and content
> - Safe rendering helpers in `lib/nex/agent/runner.ex`
> - Unique-name tool definition merge before LLM submission
> - Inbound/Feishu-path regression proving the raw crash text is no longer echoed
> **Effort**: Medium
> **Parallel**: YES - 2 waves
> **Critical Path**: 1 -> 2 -> 5 -> F1-F4

## Context
### Original Request
User reported that after the six-layer evolution work, tools still appear duplicated and every Feishu message now only gets the reply `nofunction clause matching in io.chardata_to_string`.

### Interview Summary
- Actual user-visible failure is the raw Elixir exception text in Feishu, not Feishu rate-limit or send saturation.
- Existing code already prevents duplicate registration inside `Tool.Registry`; the more likely duplicate path is merged tool definitions in `Runner`.
- Existing ExUnit infrastructure is present; user chose `tests-after`.
- Default applied: medium-scope fix only. Fix root cause, add guardrails and regression tests, but do not redesign Feishu channel architecture or the six-layer evolution model.

### Metis Review (gaps addressed)
- Prioritize `lib/nex/agent/runner.ex` over Feishu channel rewrites.
- Add one safe rendering strategy for arbitrary tool args, tool results, and model content instead of scattered `to_string/1` fallbacks.
- Dedupe merged tool definitions by `name` in `Runner`, preferring registry tools over skill tools on conflict.
- Keep CI changes out of scope for this fix; note them as follow-up only.

## Work Objectives
### Core Objective
Eliminate the runtime path that converts structured values into invalid chardata during the Feishu request cycle, and ensure the model sees each tool name at most once.

### Deliverables
- Updated Runner logic that safely renders arbitrary args, results, and content to binary text.
- Updated Runner tool-definition merge logic with deterministic unique-name output.
- Targeted ExUnit coverage for the exact crash symptom and the duplicate-tool-definition regression.
- One outbound-path regression proving a user no longer sees the raw `io.chardata_to_string` exception text.

### Definition of Done (verifiable conditions with commands)
- `mix test test/nex/agent/runner_evolution_test.exs` passes with new non-binary args, result, and content regressions.
- `mix test test/nex/agent/tool_alignment_test.exs` passes with a new unique-tool-name assertion.
- `mix test test/nex/agent/inbound_worker_test.exs` passes with a regression proving the raw `io.chardata_to_string` text is not echoed after the fix.
- `mix test test/nex/agent` passes with `0 failures`.

### Must Have
- Preserve existing behavior for already-binary tool output and normal Feishu replies.
- Prefer registry tool definitions when a skill tool has the same exposed name.
- Render structured values with safe text conversion before any `String.*` processing.
- Keep changes scoped to proven crash surfaces.

### Must NOT Have
- No Feishu transport rewrite.
- No broad search-and-replace of every `to_string/1` in the repo.
- No tool lifecycle redesign.
- No CI workflow expansion in this plan.

## Verification Strategy
> ZERO HUMAN INTERVENTION - all verification is agent-executed.
- Test decision: tests-after with ExUnit
- QA policy: every task includes agent-executed scenarios
- Evidence: `.sisyphus/evidence/task-{N}-{slug}.{ext}`

## Execution Strategy
### Parallel Execution Waves
Wave 1: task 1 `unspecified-high`, task 3 `quick`
Wave 2: task 2 `unspecified-high`, task 4 `quick`, task 5 `unspecified-high`

### Dependency Matrix (full)
- 1 blocks 2 and 5
- 3 blocks 4
- 2 and 4 both block 5
- 5 blocks F1-F4

### Agent Dispatch Summary
- Wave 1 -> 2 tasks -> `unspecified-high`, `quick`
- Wave 2 -> 3 tasks -> `unspecified-high`, `quick`, `unspecified-high`
- Final -> 4 tasks -> `oracle`, `unspecified-high`, `unspecified-high`, `deep`

## TODOs
> Implementation + Test = ONE task. Never separate.

- [x] 1. Add failing Runner crash regressions

  **What to do**: Extend `test/nex/agent/runner_evolution_test.exs` with regressions that drive `Runner.run/3` through structured tool args, structured tool results, and structured model content that previously hit unsafe `to_string/1` or `String.*` paths. Use stubbed `llm_client` and tool results that include nested lists and maps, not just binaries.
  **Must NOT do**: Do not change production code in this task. Do not add broad integration fixtures. Do not depend on live Feishu credentials.

  **Recommended Agent Profile**:
  - Category: `unspecified-high` - Reason: needs careful Elixir test design around async runner behavior
  - Skills: `[]` - no extra skill required
  - Omitted: `git-master` - no git work needed

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: [2, 5] | Blocked By: []

  **References**:
  - Pattern: `test/nex/agent/runner_evolution_test.exs:37` - existing stubbed LLM-driven Runner regressions
  - Pattern: `lib/nex/agent/runner.ex:423` - progress path currently strips think tags with `String.replace` and `String.trim`
  - Pattern: `lib/nex/agent/runner.ex:469` - unsafe `normalize_tool_hint_args/2` fallback
  - Pattern: `lib/nex/agent/runner.ex:816` - unsafe tool result fallback in `execute_tool/3`
  - Pattern: `lib/nex/agent/runner.ex:836` - unsafe skill fallback in `execute_tool_fallback/3`

  **Acceptance Criteria**:
  - [ ] `mix test test/nex/agent/runner_evolution_test.exs` fails before production changes because the new regressions reproduce the crash or unsafe output
  - [ ] Added tests use concrete structured values such as `%{"nested" => [%{"x" => 1}]}` and `[ %{"a" => 1} ]`

  **QA Scenarios**:
  ```text
  Scenario: Structured tool result
    Tool: Bash
    Steps: run `mix test test/nex/agent/runner_evolution_test.exs`
    Expected: new regression fails on current code at the Runner stringification path
    Evidence: .sisyphus/evidence/task-1-runner-crash.txt

  Scenario: Structured model content
    Tool: Bash
    Steps: run `mix test test/nex/agent/runner_evolution_test.exs --seed 0`
    Expected: a test exercising non-binary content fails before the fix, not a random unrelated test
    Evidence: .sisyphus/evidence/task-1-runner-content-error.txt
  ```

  **Commit**: YES | Message: `test(runner): reproduce chardata crash on structured values` | Files: [`test/nex/agent/runner_evolution_test.exs`]

- [x] 2. Harden Runner rendering for arbitrary values

  **What to do**: Update `lib/nex/agent/runner.ex` so every Runner-owned user-facing or log-facing string conversion goes through one safe helper. Cover at least these sites: `normalize_tool_hint_args/2`, `strip_think_tags/1` caller expectations, `execute_tool/3`, `execute_tool_fallback/3`, `maybe_publish_tool_results/2`, and any nearby preview logic that currently assumes binaries. Use deterministic rendering rules: keep binaries unchanged; JSON-encode maps and lists when encodable; otherwise use bounded `inspect/2`; never call raw `to_string/1` on arbitrary terms.
  **Must NOT do**: Do not touch unrelated modules. Do not swallow tool errors silently. Do not change binary outputs beyond normalization needed for safety.

  **Recommended Agent Profile**:
  - Category: `unspecified-high` - Reason: production bugfix in central orchestration logic
  - Skills: `[]` - no extra skill required
  - Omitted: `playwright` - no browser work

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [5] | Blocked By: [1]

  **References**:
  - API/Type: `lib/nex/agent/runner.ex:284` - tool-call handling entry point
  - Pattern: `lib/nex/agent/runner.ex:423` - progress emission path
  - Pattern: `lib/nex/agent/runner.ex:439` - tool-hint formatting path
  - Pattern: `lib/nex/agent/runner.ex:801` - tool execution result normalization path
  - Pattern: `lib/nex/agent/runner.ex:485` - tool result publishing path

  **Acceptance Criteria**:
  - [ ] `mix test test/nex/agent/runner_evolution_test.exs` passes after the change
  - [ ] Structured args, results, and content are converted to binary output without raising `FunctionClauseError` or `Protocol.UndefinedError`
  - [ ] Existing binary-only Runner tests still pass unchanged

  **QA Scenarios**:
  ```text
  Scenario: Happy path safe rendering
    Tool: Bash
    Steps: run `mix test test/nex/agent/runner_evolution_test.exs`
    Expected: all Runner evolution tests pass, including new structured-value cases
    Evidence: .sisyphus/evidence/task-2-runner-pass.txt

  Scenario: Edge case nested list and map
    Tool: Bash
    Steps: run `mix test test/nex/agent/runner_evolution_test.exs --seed 0`
    Expected: no output contains `nofunction clause matching in io.chardata_to_string`
    Evidence: .sisyphus/evidence/task-2-runner-no-chardata.txt
  ```

  **Commit**: YES | Message: `fix(runner): safely render structured tool values` | Files: [`lib/nex/agent/runner.ex`, `test/nex/agent/runner_evolution_test.exs`]

- [x] 3. Add failing duplicate-tool-definition regression

  **What to do**: Extend `test/nex/agent/tool_alignment_test.exs` or add a focused Runner/tool-merge regression proving that when registry tools and skill tools expose the same `name`, the merged tool list passed to the model contains that name once. Encode the precedence rule in the test: registry definition wins, skill duplicate is dropped.
  **Must NOT do**: Do not implement dedupe logic in this task. Do not rely on manual inspection of tool arrays.

  **Recommended Agent Profile**:
  - Category: `quick` - Reason: isolated regression around merge semantics
  - Skills: `[]` - no extra skill required
  - Omitted: `git-master` - no git work needed

  **Parallelization**: Can Parallel: YES | Wave 1 | Blocks: [4] | Blocked By: []

  **References**:
  - Pattern: `test/nex/agent/tool_alignment_test.exs:35` - current tool metadata assertions
  - Pattern: `lib/nex/agent/runner.ex:654` - merged tool definition assembly starts here
  - Pattern: `lib/nex/agent/runner.ex:681` - current `registry_defs ++ skill_tools` concatenation
  - Pattern: `lib/nex/agent/tool/registry.ex:155` - registry definitions are already name-addressable

  **Acceptance Criteria**:
  - [ ] `mix test test/nex/agent/tool_alignment_test.exs` fails before production changes because the new unique-name assertion catches duplicate exposure
  - [ ] Test explicitly checks that the final merged list contains one `message`-like duplicate candidate, not two

  **QA Scenarios**:
  ```text
  Scenario: Duplicate name regression
    Tool: Bash
    Steps: run `mix test test/nex/agent/tool_alignment_test.exs`
    Expected: new duplicate-name regression fails on current merge behavior
    Evidence: .sisyphus/evidence/task-3-tool-dedupe-fail.txt

  Scenario: Precedence rule encoded
    Tool: Bash
    Steps: run `mix test test/nex/agent/tool_alignment_test.exs --seed 0`
    Expected: failure message makes clear that registry definition should win over skill duplicate
    Evidence: .sisyphus/evidence/task-3-tool-dedupe-precedence.txt
  ```

  **Commit**: YES | Message: `test(runner): cover duplicate tool definition exposure` | Files: [`test/nex/agent/tool_alignment_test.exs`]

- [x] 4. Dedupe merged tool definitions before LLM submission

  **What to do**: Update `lib/nex/agent/runner.ex` `registry_definitions/2` flow so registry definitions and skill definitions are merged by unique tool `name` before validation and before `ReqLLM` transformation. Preserve registry-first precedence and keep invalid-name dropping behavior unchanged.
  **Must NOT do**: Do not change `Tool.Registry` registration semantics. Do not rename tools. Do not reorder unrelated tools except as required by deterministic dedupe.

  **Recommended Agent Profile**:
  - Category: `quick` - Reason: narrow production change in one function
  - Skills: `[]` - no extra skill required
  - Omitted: `playwright` - no UI work

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [5] | Blocked By: [3]

  **References**:
  - Pattern: `lib/nex/agent/runner.ex:654` - tool-definition builder entry point
  - Pattern: `lib/nex/agent/runner.ex:681` - current concatenation site
  - Pattern: `lib/nex/agent/skills.ex:142` - skill tool names are emitted as ordinary tool names
  - Pattern: `lib/nex/agent/llm/req_llm.ex:157` - downstream tool transformation expects clean unique definitions

  **Acceptance Criteria**:
  - [ ] `mix test test/nex/agent/tool_alignment_test.exs` passes after the change
  - [ ] Final tool-definition list submitted to the LLM contains unique names only
  - [ ] Registry-first precedence is covered by test, not just implementation comments

  **QA Scenarios**:
  ```text
  Scenario: Unique tool names
    Tool: Bash
    Steps: run `mix test test/nex/agent/tool_alignment_test.exs`
    Expected: duplicate-name regression passes and final merged tool names are unique
    Evidence: .sisyphus/evidence/task-4-tool-dedupe-pass.txt

  Scenario: Invalid name behavior unchanged
    Tool: Bash
    Steps: run `mix test test/nex/agent/runner_evolution_test.exs test/nex/agent/tool_alignment_test.exs`
    Expected: no new failure around invalid-name dropping or tool registration order
    Evidence: .sisyphus/evidence/task-4-tool-dedupe-safety.txt
  ```

  **Commit**: YES | Message: `fix(runner): dedupe merged tool definitions by name` | Files: [`lib/nex/agent/runner.ex`, `test/nex/agent/tool_alignment_test.exs`]

- [x] 5. Prove the Feishu-visible symptom is gone

  **What to do**: Add a regression test around `InboundWorker` and, only if necessary, a narrow Feishu-path test that simulates the previous Runner failure mode and verifies the outbound content no longer contains the raw `nofunction clause matching in io.chardata_to_string` text. If task 2 fully fixes the symptom through Runner hardening, keep production changes in `InboundWorker` and `Feishu` to zero and only add tests. Only add code outside `Runner` if a test proves a non-binary value still reaches `String.trim` or `String.split` in `InboundWorker` or `Feishu`.
  **Must NOT do**: Do not preemptively rewrite `Feishu.do_send/2`. Do not add live-channel integration tests. Do not change user-facing formatting unless required for safety.

  **Recommended Agent Profile**:
  - Category: `unspecified-high` - Reason: symptom-proof regression across module boundaries
  - Skills: `[]` - no extra skill required
  - Omitted: `playwright` - no browser work

  **Parallelization**: Can Parallel: NO | Wave 2 | Blocks: [F1, F2, F3, F4] | Blocked By: [1, 2, 4]

  **References**:
  - Pattern: `lib/nex/agent/inbound_worker.ex:78` - async success path publishes user-visible outbound replies
  - Pattern: `lib/nex/agent/inbound_worker.ex:95` - async error path formats exception text back to the channel
  - Pattern: `lib/nex/agent/channel/feishu.ex:818` - Feishu send path assumes binary content
  - Pattern: `lib/nex/agent/channel/feishu.ex:893` - interactive-card renderer assumes binary content
  - Pattern: `test/nex/agent/runner_evolution_test.exs:42` - existing async runner testing style to mirror

  **Acceptance Criteria**:
  - [ ] `mix test test/nex/agent/inbound_worker_test.exs` passes with a regression covering the prior Feishu-visible crash text
  - [ ] `mix test test/nex/agent` passes with `0 failures`
  - [ ] No assertion output contains `nofunction clause matching in io.chardata_to_string`

  **QA Scenarios**:
  ```text
  Scenario: No raw exception echo
    Tool: Bash
    Steps: run `mix test test/nex/agent/inbound_worker_test.exs`
    Expected: outbound payload is a normal safe-rendered reply or a controlled error, not the raw chardata exception text
    Evidence: .sisyphus/evidence/task-5-inbound-safe.txt

  Scenario: Full focused agent suite
    Tool: Bash
    Steps: run `mix test test/nex/agent`
    Expected: agent test suite passes with zero failures and no chardata exception text
    Evidence: .sisyphus/evidence/task-5-agent-suite.txt
  ```

  **Commit**: YES | Message: `test(feishu): lock out raw chardata exception replies` | Files: [`test/nex/agent/inbound_worker_test.exs`, `test/nex/agent/runner_evolution_test.exs`, `test/nex/agent/tool_alignment_test.exs`]

## Final Verification Wave (4 parallel agents, ALL must APPROVE)
- [ ] F1. Plan Compliance Audit - oracle
- [ ] F2. Code Quality Review - unspecified-high
- [ ] F3. Real Manual QA - unspecified-high
- [ ] F4. Scope Fidelity Check - deep

## Commit Strategy
- Commit 1: `test(runner): reproduce chardata crash on structured values`
- Commit 2: `fix(runner): safely render structured tool values`
- Commit 3: `test(runner): cover duplicate tool definition exposure`
- Commit 4: `fix(runner): dedupe merged tool definitions by name`
- Commit 5: `test(feishu): lock out raw chardata exception replies`

## Success Criteria
- Feishu users no longer receive the raw `io.chardata_to_string` exception for ordinary messages.
- Runner safely handles structured args, structured tool results, and structured LLM content.
- The LLM-visible tool list contains unique tool names with registry-first precedence.
- All targeted agent tests pass locally with no manual verification step.
