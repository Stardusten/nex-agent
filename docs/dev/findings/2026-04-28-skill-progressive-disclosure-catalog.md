# Skill Progressive Disclosure Catalog

## 结论

Nex 的 skill 主链必须采用 steady cards + on-demand body 的 progressive disclosure 模型：

```text
runtime reload / each LLM request
  -> collect model-invocable skill records
  -> put only id + description into the steady system prompt
  -> when the model needs one skill, call skill_get(id)
  -> skill_get reads that SKILL.md body and lists bundled resources
  -> extra resource files stay on demand
```

本次纠偏选择删掉旧 SkillRuntime 主线，而不是保留兼容模式：

- no `SkillRuntime` package registry / prepare-run / imported-package execution layer
- no `skill_discover`, `skill_import`, or `skill_sync` model-visible tools
- no `skill_run__*` ephemeral tools
- no `skill_get(name, source)` activation path
- no legacy `skill_id` alias
- no `always: true` body injection path

Workbench app authoring 是 CODE-layer builtin skill：`builtin:workbench-app-authoring`。它的 card 常驻，正文只通过 `skill_get(id)` 加载；Workbench app 文件开发继续走 `find` / `read` / `apply_patch`，不新增平行文件编辑 tool，也不把 notes、stocks 等领域 app schema 放进核心 Workbench 或 builtin skill。

同一原则也适用于已有常驻 system prompt 中的长篇、低频操作指导。凡是“只在特定场景才用、内容较长、触发语义清楚”的 prompt，都应抽成 builtin skill；常驻 prompt 只留下短路由和 `skill_get(id)` 规则。

本轮抽取后的 builtin 分组不是一段 prompt 对应一个 skill，而是按稳定工作流边界合并：

- `builtin:nex-code-maintenance`: CODE self-update/deploy/rollback、owner/subagent CODE 边界、ReqLLM/provider adapter、Anthropic `tool_choice` 和 CODE 验证策略。
- `builtin:runtime-observability`: ControlPlane/`observe`/`/status`、run gauge、follow-up、incident、budget、background evidence。
- `builtin:memory-and-evolution-routing`: six-layer routing、memory refresh/status/rebuild、用户纠正沉淀、owner-approved `evolution_candidate` lane。
- `builtin:lark-feishu-ops`: Feishu native message/media、`lark-cli` business operations、旧 `feishu_*` tool 边界。
- `builtin:workbench-app-authoring`: Workbench app artifact authoring、manifest/permissions/static assets、app-local `reload.sh` refresh contract。

这些 skill 的 description 是触发面，正文是按需加载的操作手册。不要把这些正文重新塞回 `ContextBuilder`、onboarding `AGENTS.md`、或 `TOOLS.md` 模板里。

## 外部证据

- Agent Skills specification defines progressive disclosure as startup metadata, activated `SKILL.md`, then extra resources on demand. Source: https://agentskills.io/specification
- Agent Skills client implementation guide describes a model-visible catalog and model-driven activation. Source: https://agentskills.io/client-implementation/adding-skills-support
- OpenAI Codex docs say Codex begins with skill name, description, and path, then loads the full `SKILL.md` only after deciding to use a skill; the initial list is budgeted. Source: https://developers.openai.com/codex/skills
- Claude skills overview says Claude reads names/descriptions at startup, loads full `SKILL.md` when a task matches, and loads additional files only when needed. Source: https://claude.com/docs/skills/overview
- Claude Code skills docs define model visibility through the skill description and load full content on invocation; `disable-model-invocation: true` removes the skill from model context. Source: https://code.claude.com/docs/en/skills
- OpenCode docs use a native `skill` tool with an `<available_skills>` list of names/descriptions and a tool call to load full content. Source: https://opencode.ai/docs/skills

这些 systems 不完全同构：Codex may show file path internally; OpenCode uses skill name; Nex chooses a stricter model-facing contract of `id + description` only. The shared architectural point is stable lightweight discovery plus explicit body activation.

## Nex 原偏差

- `ContextBuilder` only told the model to use runtime skill discovery tools; normal workspace skill descriptions were absent from the prompt.
- `Runtime.Snapshot.skills` carried only `always_instructions` / hash, so there was no durable skill catalog in the runtime world view.
- `always: true` skills injected full bodies into the steady prompt, while ordinary skills had neither bodies nor cards.
- `skill_get` and discovery/import/sync tools were coupled to disabled-by-default SkillRuntime state, so ordinary builtin/workspace skills were not reliable core capabilities.
- `SkillRuntime.prepare_run/2` preselected packages and injected fragments before the model chose a skill, inverting progressive disclosure.
- Tests locked in the wrong behavior by asserting ordinary skill names/bodies were absent rather than asserting compact cards were present and bodies absent.

## Corrected Contract

### Skill Sources

Nex core recognizes three local sources:

- `builtin`: packaged under `priv/plugins/builtin/skill.<name>/skills/<name>/SKILL.md`; CODE-layer runtime assets owned by builtin skill plugins.
- `workspace`: user/agent-authored skills under `workspace/skills/<name>/SKILL.md`.
- `project`: repo-local skills under the active project skill directory.

Imported or remote skills are not a separate core source after this correction. A future installer may materialize an approved remote skill as an ordinary workspace skill, but it must not reintroduce a parallel runtime package registry or hidden execution layer.

### Prompt Cards

The steady prompt projection is the only model-facing discovery surface for installed local skills:

```elixir
%{
  "id" => String.t(),
  "description" => String.t()
}
```

Prompt section:

```text
## Available Skills
These skill cards stay current for this LLM request. When the task matches a description, call `skill_get` with the skill `id` before following the skill.

<available_skills>
  <skill id="builtin:workbench-app-authoring">
    <description>...</description>
  </skill>
</available_skills>
```

The prompt must not include skill body, path, source, name, root directory, resource list, or runtime metadata. The catalog is steady only because the current runtime system prompt is included on every owner, follow-up, subagent, and cron LLM request that exposes `skill_get`; it must not rely on a one-time first session message that can be removed by history trimming or provider compaction.

### Runtime Snapshot

`Runtime.Snapshot.skills` is the runtime truth source for prompt projection and deterministic resolution:

```elixir
%{
  cards: [map()],
  catalog_prompt: String.t(),
  diagnostics: [map()],
  hash: String.t()
}
```

`catalog_prompt` is the exact prompt projection. `cards` may contain resolver metadata such as path and source, but that metadata is not prompt-visible. There is no `always_instructions` compatibility field.

### Activation Tool

`skill_get` is the single model-visible activation tool:

```elixir
%{"id" => String.t()}
```

It reads builtin/workspace/project `SKILL.md` through the catalog. It does not accept `name`, `source`, or `skill_id`. It does not depend on any SkillRuntime enabled flag.

### Runner

The default `Runner.run/3` path must not:

- call prepare-run skill search
- inject selected skill fragments
- append skill package system messages
- expose synthetic `skill_run__*` tools

The model first sees cards, then explicitly calls `skill_get(id)`.

## Required Contract Tests

- workspace skill card appears in prompt as `id + description`; body/path/source/name do not.
- `always: true` frontmatter does not preload the body.
- `disable-model-invocation: true` hides the card.
- `user-invocable: false` remains model-visible if not draft/disabled.
- draft skills are hidden and rejected until published.
- builtin `builtin:workbench-app-authoring` card appears and `skill_get(id)` returns its body.
- `skill_get` rejects `name` and old `skill_id` alias.
- runtime snapshot has `skills.cards`, `skills.catalog_prompt`, `skills.diagnostics`, and `skills.hash`.
- after history trimming, the final LLM messages still contain the current skill catalog.
- default tool surfaces contain `skill_get` and `skill_capture`, but not `skill_discover`, `skill_import`, `skill_sync`, `skill_list`, or `skill_read`.
- no `workbench_app`, `write_file`, `save_manifest`, or domain app schema tools appear.
