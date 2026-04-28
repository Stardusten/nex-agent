# Phase 18C Skill Progressive Disclosure Catalog Cutover

## 当前状态

Phase 18B Workbench static app runtime 已完成。Skill 主链存在基础架构偏差：

- 普通 workspace skill 没有稳定的 model-facing card；旧 prompt 只让模型找 runtime discovery 工具。
- `always: true` skill body 会常驻 prompt，和正文按需加载模型冲突。
- 旧 `SkillRuntime` 同时负责 package registry、remote import、prepare-run 自动检索、正文注入、ephemeral tool 暴露，绕过了模型先看 card 再主动加载正文的流程。
- 旧 skill tools 包含 discovery/import/sync/list/read 等平行入口，且 `skill_get` 曾支持 `name/source` 和 `skill_id` alias。

## 完成后必须达到的结果

1. System prompt 每次 LLM request 都包含当前 runtime skill catalog；catalog 不依赖对话开头的一次性消息。
2. Prompt-visible skill card 只包含 `id` 和 `description`。
3. 普通 skill、builtin skill、`always: true` skill 的正文都不常驻；正文只通过 `skill_get(id)` 加载。
4. `skill_get` 只接受 `id`，不接受 `name`、`source` 或 `skill_id` alias。
5. Core skill sources 只保留 builtin / workspace / project；旧 SkillRuntime imported package source 不保留。
6. 旧 `SkillRuntime` 模块、runtime package tests、fixtures、`skill_discover`、`skill_import`、`skill_sync`、`skill_list`、`skill_read` 删除。
7. `Runner.run/3` 默认路径不再做 skill prepare-run、selected fragment injection 或 `skill_run__*` ephemeral tool exposure。
8. Workbench app authoring 作为 `builtin:workbench-app-authoring` 提供；开发 app 仍走 `find` / `read` / `apply_patch`，不新增 `workbench_app`、`write_file`、`save_manifest` 或领域 app schema tool。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/findings/2026-04-28-skill-progressive-disclosure-catalog.md`
- `docs/dev/designs/2026-04-28-workbench-app-authoring-guide.md`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/skills.ex`
- `lib/nex/agent/skills/loader.ex`
- `lib/nex/agent/tool/skill_get.ex`
- `lib/nex/agent/tool/skill_capture.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/tool/tool_list.ex`
- `lib/nex/agent/runner.ex`
- `test/nex/agent/context_builder_test.exs`
- `test/nex/agent/runtime_test.exs`
- `test/nex/agent/skills_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. Prompt card shape:

```elixir
%{
  "id" => String.t(),
  "description" => String.t()
}
```

Prompt projection 不包含 `name`、`source`、`path`、`root_path`、`resources`、body 或 runtime debug metadata。

2. Runtime snapshot skill shape:

```elixir
%{
  cards: [map()],
  catalog_prompt: String.t(),
  diagnostics: [map()],
  hash: String.t()
}
```

No `always_instructions`.

3. Skill source ids:

```text
builtin:<name>
workspace:<name>
project:<name>
```

No `imported:<id>` source in core Phase 18C.

4. `skill_get` input:

```elixir
%{"id" => String.t()}
```

Reject missing `id`, `name`, `source`, and old `skill_id` alias.

5. `skill_get` output:

```elixir
%{
  "id" => String.t(),
  "content" => String.t(),
  "resources" => [String.t()]
}
```

Output may include runtime diagnostic metadata, but callers must not depend on `name/source` activation support.

6. Builtin skill location:

```text
priv/skills/builtin/<name>/SKILL.md
```

`priv/skills/code-review` and `priv/skills/pulse` remain repo-local operational skills, not builtin runtime skills.

7. Model visibility:

```text
draft skill -> hidden from cards
disable-model-invocation: true -> hidden from cards
user-invocable: false -> visible to model if not draft and not disabled
always: true -> ignored for body preloading
```

8. Steady prompt:

```text
Current runtime system prompt must include Runtime.Snapshot.skills.catalog_prompt
for every LLM request that exposes skill_get.
```

Sliding-window trimming and provider-native compaction may remove conversation history, but must not remove the current request's runtime system prompt/catalog.

9. Deleted tool surface:

```text
skill_discover
skill_import
skill_sync
skill_list
skill_read
skill_run__*
```

These names must not appear in default, follow-up, subagent, or cron tool definitions.

## 执行顺序 / stage 依赖

- Stage 1: delete legacy SkillRuntime modules and model-visible tools.
- Stage 2: add local skill catalog and builtin Workbench authoring skill.
- Stage 3: wire runtime snapshot and prompt projection.
- Stage 4: make `skill_get` id-only and remove Runner auto-injection.
- Stage 5: update tests and docs.

Stage 2 depends on Stage 1 for source boundaries. Stage 3 depends on Stage 2. Stage 4 can run after Stage 2 and must finish before Stage 5.

## Stage 1

### 前置检查

- Confirm no public external API contract requires SkillRuntime package execution.
- Confirm Workbench authoring does not require any new file-editing tool.

### 这一步改哪里

- Delete `lib/nex/skill_runtime.ex`
- Delete `lib/nex/skill_runtime/**`
- Delete `lib/nex/agent/tool/skill_discover.ex`
- Delete `lib/nex/agent/tool/skill_import.ex`
- Delete `lib/nex/agent/tool/skill_sync.ex`
- Delete `lib/nex/agent/tool/skill_list.ex`
- Delete `lib/nex/agent/tool/skill_read.ex`
- Delete `test/nex/skill_runtime/**`
- Delete `test/nex/e2e/skill_runtime_e2e_test.exs`
- Delete `test/nex/e2e/skill_runtime_live_e2e_test.exs`
- Delete `test/support/fixtures/skill_runtime/**`
- Update `lib/nex/agent/config.ex`
- Update `lib/nex/agent/workspace.ex`

### 这一步要做

- Remove SkillRuntime config accessor and workspace directory helper.
- Remove package registry, manifest, GitHub import, skill runner, prepared run, validation, evolution event, and store modules.
- Move only reusable frontmatter parsing into the agent skill namespace.

### 实施注意事项

- Do not add compatibility shims for deleted modules.
- Use compile errors to migrate every caller.

### 本 stage 验收

- `rg "Nex\\.SkillRuntime|SkillRuntime|skill_runtime" lib test` returns no live code/test references.
- Deleted tool modules are absent.

### 本 stage 验证

```bash
/opt/homebrew/bin/mix compile --warnings-as-errors
```

## Stage 2

### 前置检查

- Confirm `Skills.Loader` can load workspace and project Markdown skills.
- Confirm builtin runtime skills must not include repo-local operational skills.

### 这一步改哪里

- Add `lib/nex/agent/skills/catalog.ex`
- Add `lib/nex/agent/skills/frontmatter.ex`
- Update `lib/nex/agent/skills.ex`
- Update `lib/nex/agent/subagent/profiles.ex`
- Add `priv/skills/builtin/workbench-app-authoring/SKILL.md`
- Update `test/nex/agent/skills_test.exs`

### 这一步要做

- Build catalog cards from builtin, workspace, and project skills.
- Render prompt catalog with only `id` and `description`.
- Respect draft / `disable-model-invocation` / `user-invocable` visibility.
- Add builtin Workbench app authoring instructions that use only `find` / `read` / `apply_patch`.

### 实施注意事项

- Do not scan SkillRuntime `rt__*` or `gh__*` directories as a special imported source.
- Do not put domain app schemas into the builtin Workbench skill.

### 本 stage 验收

- `Skills.for_llm/1` returns maps with only `id` and `description`.
- `Skills.catalog_prompt/1` contains no path/source/name/body.

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/skills_test.exs
```

## Stage 3

### 前置检查

- Confirm runtime snapshot is the prompt/tools/config truth source.

### 这一步改哪里

- Update `lib/nex/agent/runtime/snapshot.ex`
- Update `lib/nex/agent/runtime.ex`
- Update `lib/nex/agent/context_builder.ex`
- Update `test/nex/agent/runtime_test.exs`
- Update `test/nex/agent/context_builder_test.exs`

### 这一步要做

- Add `skills.cards`, `skills.catalog_prompt`, `skills.diagnostics`, and `skills.hash`.
- Pass `skills.catalog_prompt` into prompt build on each runtime reload.
- Remove `always: true` body injection from `ContextBuilder`.
- Keep skill catalog in the current request's system prompt after history trimming.

### 实施注意事项

- Do not store catalog as a one-time session message.
- Do not make `always: true` a second hidden instruction channel.

### 本 stage 验收

- System prompt contains `## Available Skills`.
- Workspace skill body is absent until `skill_get`.
- `always: true` skill body is absent.

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/context_builder_test.exs test/nex/agent/runtime_test.exs
```

## Stage 4

### 前置检查

- Confirm model-visible activation should be one tool: `skill_get`.

### 这一步改哪里

- Update `lib/nex/agent/tool/skill_get.ex`
- Update `lib/nex/agent/tool/skill_capture.ex`
- Update `lib/nex/agent/tool/registry.ex`
- Update `lib/nex/agent/tool/tool_list.ex`
- Update `lib/nex/agent/follow_up.ex`
- Update `lib/nex/agent/runner.ex`
- Update `lib/nex/agent/control_plane/query.ex`
- Update `lib/nex/agent/admin.ex`
- Update `lib/nex/agent/onboarding.ex`
- Update `test/nex/agent/tool_alignment_test.exs`
- Update `test/nex/agent/control_plane_store_test.exs`
- Update `test/nex/agent/runner_evolution_test.exs`
- Update `test/nex/agent/admin_test.exs`

### 这一步要做

- Make `skill_get` schema require only `id`.
- Reject `name` and old `skill_id` alias.
- Resolve `id` through runtime snapshot catalog cards when available.
- Remove `SkillRuntime.prepare_run/2`, prepared run state, selected package trace attrs, package finalization, and `skill_run__*` execution from Runner.
- Remove deleted tools from all surfaces and admin projections.

### 实施注意事项

- Do not preserve hidden auto-select behavior behind config.
- Do not leave deleted tool names in follow-up/subagent/cron surfaces.

### 本 stage 验收

- Registry starts without discovery/import/sync/list/read skill tools.
- Runner LLM request tool list has no `skill_run__*`.
- `skill_get(%{"name" => ...})` and old alias args return `id is required`.

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/tool_alignment_test.exs test/nex/agent/runner_evolution_test.exs test/nex/agent/admin_test.exs
```

## Stage 5

### 前置检查

- Confirm focused contract tests pass.

### 这一步改哪里

- Update `docs/dev/findings/2026-04-28-skill-progressive-disclosure-catalog.md`
- Update `docs/dev/task-plan/phase18c-skill-progressive-disclosure-catalog.md`
- Update `docs/dev/progress/CURRENT.md`
- Update `docs/dev/progress/2026-04-28.md`

### 这一步要做

- Record the no-legacy final contract.
- Remove compatibility wording around imported runtime packages, `always_instructions`, `skill_discover`, name/source activation, and SkillRuntime prepare-run.
- Record validation commands and results.

### 实施注意事项

- Historical older phase docs may mention old contracts as history, but active Phase 18C docs must describe the final no-legacy contract.

### 本 stage 验收

- Active docs match implementation and tests.

### 本 stage 验证

```bash
rg -n "SkillRuntime|skill_runtime|skill_discover|skill_import|skill_sync|skill_id|always_instructions|skill_run__" lib test
/opt/homebrew/bin/mix compile --warnings-as-errors
```

## Review Fail 条件

- Any live `lib/` or `test/` reference to deleted SkillRuntime modules or deleted skill tools remains.
- Prompt-visible skill cards include path/source/name/body.
- `always: true` body is still injected into the steady prompt.
- `skill_get` accepts `name`, `source`, or old `skill_id` alias.
- `Runner` defaults still inject selected skill package fragments or exposes `skill_run__*`.
- `workbench-app-authoring` depends on external SkillRuntime config to be visible or readable.
- Workbench app authoring introduces new parallel file editing tools or domain-specific app schemas.
