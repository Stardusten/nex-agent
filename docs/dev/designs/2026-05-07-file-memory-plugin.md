# File Memory System And Builtin Memory Plugin

## 背景

现有 memory 主链是 workspace-global `memory/MEMORY.md`，由 `ContextBuilder` 每轮注入，由 `Memory.refresh/4` 和 `MemoryUpdater` 从 session history 后台整理。这条路线简单、可用、可见性也在 Phase 17 后有所改善，但它仍然是 core 特例：

- prompt 注入硬编码 `memory/MEMORY.md`
- watcher 硬编码 `memory/MEMORY.md`
- 后台 refresh 是专用 GenServer
- memory tools 虽然已包装成 plugin contribution，但内部仍依赖 `Nex.Agent.Knowledge.Memory`

新的方向是：把内置记忆系统设计成普通 builtin plugin。它不要求所有记忆系统都长得一样，也不要求 plugin host 提供 memory-specific interface。外部记忆服务、SQLite/FTS、mem0/mem9、文件记忆都可以是不同插件。

本文描述自带 file memory plugin 的产品语义和实现草案。它依赖通用插件 primitives：workspace artifacts、context contributions、tools、skills、events、queues/jobs、permissions、observability、migrations。

## 目标心智

内置记忆系统是一个文件化 workspace knowledge substrate：

- 底层内容是一份份 Markdown 文件。
- 常驻上下文只注入最高级地图和收件箱，不永久塞入所有历史。
- LLM 通过非常少的专用工具写入/读取记忆文件。
- 其他结构不预设，由 agent 在 skill 指导下逐步整理。
- 原始对话和 session history 不因为 context 裁剪而丢失；需要时可以通过 read/find/session tools 追溯。
- 记忆整理是后台 job 或显式 maintenance，不是每轮强行全量 rewrite。

## Plugin 形态

插件 id 草案：

```text
builtin:memory.files
```

插件贡献：

```text
workspace_artifacts:
  memory/
  memory/INDEX.md
  memory/INBOX.md

context:
  memory.files.index -> inject memory/INDEX.md
  memory.files.inbox -> inject memory/INBOX.md

tools:
  memory__write
  memory__read

skills:
  memory-files/SKILL.md

queues/jobs:
  memory.files.organize (later)
  memory.files.capture-after-turn (optional, later)

permissions:
  read/write workspace:memory/**
```

这不是 `memory` contribution kind。它只是普通 plugin capabilities 的组合。

## Workspace 文件结构

最小结构：

```text
memory/
  INDEX.md
  INBOX.md
```

约束：

- `INDEX.md` 是顶层地图，短、稳定、偏导航。
- `INBOX.md` 是尚未整理的记忆条目，普通写入默认 append 到这里。
- 其他目录和文件不预设。LLM 可以在整理阶段自行创建，例如 `topics/`、`projects/`、`people/`、`conversations/`。
- 不要求 `MEMORY.md` 继续存在；如果迁移期保留，它只是旧系统兼容输入，不是新插件的唯一真相源。

推荐模板：

```markdown
# Memory Index

This file is the top-level map for workspace memory. Keep it short and navigational.

## Active Areas

- `INBOX.md` - new unsorted memory entries.

## Conventions

- New memory is appended to `INBOX.md` first.
- Organize only when explicitly doing memory maintenance or background curation.
```

```markdown
# Memory Inbox

Append new unsorted durable memory entries here. Keep each entry dated and source-aware.
```

## 常驻上下文

每轮 owner/follow-up/subagent/cron turn 是否注入，由通用 context contribution 的 pointcut/surface 决定。内置 file memory 默认：

```text
memory/INDEX.md: 注入普通 owner/base turn，稳定优先级较高
memory/INBOX.md: 注入普通 owner/base turn，排在 INDEX 之后，volatile
```

排序原则：

```text
stable bootstrap / identity context
memory/INDEX.md
active task context
memory/INBOX.md
volatile request/channel context
```

Cache 稳定性规则：

- `INDEX.md` 应尽量短且少改。
- `INBOX.md` 只尾部追加，不倒序插入，不每次重排。
- 自动整理不应在高频对话中反复 rewrite `INDEX.md`。
- context renderer 应把 stable fragments 排在 volatile fragments 之前。

如果 `INBOX.md` 变大，第一版可按 `max_chars` 截断并暴露 content hash/source，后续通过后台整理迁移旧条目到其他文件，再更新 `INDEX.md` 指针。

## LLM 可见工具

第一版只暴露两个专用工具。

### `memory__write`

用途：追加一条新记忆。

草案输入：

```json
{
  "content": "User prefers concise Chinese responses for architecture discussions.",
  "path": "INBOX.md",
  "summary": "User prefers concise Chinese architecture discussion.",
  "tags": ["user", "preference"],
  "source": "current_turn"
}
```

行为：

- 默认 `path=INBOX.md`。
- 默认只 append，不 overwrite。
- path 限制在 workspace `memory/` 下。
- 每条 entry 自动加 metadata header 或 frontmatter-like prefix。
- 写入要原子化，失败不留下半条。
- 成功写 ControlPlane。

建议写入格式：

```markdown
## 2026-05-07T12:34:56Z - User preference

- Summary: User prefers concise Chinese architecture discussion.
- Source: session feishu:xxx, run run_...
- Tags: user, preference

User prefers concise Chinese responses for architecture discussions.
```

是否 user-visible notice 可以后续决定。第一版可以保留 Phase 17 的 “Memory - summary” 行为，但应由 memory plugin 的 tool 或 context 决定，不再由 core memory notice helper 特判。

### `memory__read`

用途：读取一份 memory 文件。

草案输入：

```json
{
  "path": "INDEX.md",
  "start_line": 1,
  "line_count": 120
}
```

行为：

- path 限制在 workspace `memory/` 下。
- 支持分页。
- 返回 path、content、total_lines、has_more、next_start_line、hash。
- 允许读取目录时列出 entries 可以考虑合并在 read 中，或后续加 `memory__list`。

### 是否需要 `memory__search`

内置 file memory v1 不必须提供。因为现有 `find` 和 `read` 已能处理 workspace 文件。

但 skill 应明确：

- 若记忆内容不在 `INDEX.md/INBOX.md` 常驻上下文里，先用 `find` 搜 `memory/`。
- 若用户问“之前/上次/记得吗/继续”，先查 `INDEX.md`，再查 `INBOX.md`，再 `find memory/`。

如果后续要支持 non-file backend，则另一个 memory plugin 可以暴露 `memory__search`，不影响 file memory plugin。

## Skill 指导

插件 skill 应负责教 LLM 怎么用，不把规则塞进 core prompt。

草案内容要点：

```text
Use this skill when the user asks about prior memory, asks you to remember something, corrects durable assumptions, or asks to organize memory.

Resident memory is only a map and inbox. It is not the full past.

Reading:
- Start with memory/INDEX.md.
- Check memory/INBOX.md for recent unsorted entries.
- Use find/read under memory/ for details.

Writing:
- Use memory__write for durable facts, decisions, preferences, or unresolved task state.
- New entries go to INBOX.md unless explicitly organizing memory.
- Do not write one-off outputs or easy-to-rediscover facts.

Organizing:
- Keep INDEX.md short and navigational.
- Move related INBOX entries into topic files only during explicit memory maintenance or background curation.
- Preserve original meaning and source pointers.
- Do not delete old entries unless there is a clear archival/migration step.
```

Layer routing remains:

- user profile preferences can still belong in `USER.md` if bootstrap USER remains core or bootstrap plugin.
- file memory is for durable workspace facts, decisions, lessons, and task context.
- reusable procedure still belongs in SKILL.
- persona belongs in SOUL.

This boundary should be expressed in the memory plugin skill, not hardcoded into a memory subsystem.

## 后台整理

第一版可以只提供 manual write/read。完整系统需要后台整理，但它应建立在通用 plugin queue/job/event primitive 上。

候选 jobs：

### Capture After Turn

触发：

```text
conversation.turn.finished
owner_run=true
from_cron=false
from_subagent=false
```

行为：

- 低成本判断本 turn 是否有 durable memory candidate。
- 有则 append 到 `INBOX.md`，或生成 proposed write。
- coalesce by `{workspace, session_key}`，避免一轮多次工具 loop 产生多条重复。

### Organize Inbox

触发：

- `INBOX.md` 超过大小阈值。
- 每日/每周 schedule。
- 用户显式要求整理记忆。

行为：

- 读取 `INDEX.md` 和 `INBOX.md`。
- 将相关条目整理到 LLM 自己选择的 topic/project/person 文件。
- 更新 `INDEX.md` 的导航指针。
- 保留 source pointer。
- 归档或标记已整理的 INBOX 条目，避免无界增长。

第一版不要急着自动 capture/organize。先把工具、context、artifact、skill 做稳定，再把后台 job 接入。

## 与旧 memory 系统的迁移关系

旧系统：

```text
memory/MEMORY.md
Memory.refresh/4
MemoryUpdater
memory_write/status/consolidate/rebuild
ContextBuilder.add_memory_with_diagnostics
```

新系统目标：

```text
builtin:memory.files
memory/INDEX.md
memory/INBOX.md
memory__write
memory__read
context contributions
plugin queues/jobs
```

迁移思路：

1. 新插件先并存，但停止新增对 `MEMORY.md` 的硬编码依赖。
2. `ContextBuilder` 不再直接读 `MEMORY.md`，由插件 context contribution 注入 `INDEX.md/INBOX.md`。
3. 旧 `memory_write` 可迁移为 `memory__write` 或保留为 deprecated alias 一段实现期，不作为长期 contract。
4. 旧 `memory_consolidate/rebuild/status` 不进入新普通模型；它们要么删除，要么变成 file memory maintenance commands/jobs。
5. `MemoryUpdater` 被 plugin queue/job 取代。
6. 旧 `MEMORY.md` 内容可通过 migration 拆成：
   - 顶层导航进入 `INDEX.md`
   - 未分类事实进入 `INBOX.md`
   - 大块主题内容进入 agent 选择的文件

是否保留 raw session consolidation 是开放问题。新 file memory 更倾向“不自动丢弃对话历史，只在需要时 search/read session archive”。

## Manifest 草案

```json
{
  "id": "builtin:memory.files",
  "title": "File Memory",
  "version": "0.1.0",
  "enabled": true,
  "source": "builtin",
  "description": "Markdown file-backed workspace memory with resident index/inbox and minimal tools.",
  "contributes": {
    "workspace_artifacts": [
      {
        "id": "memory.files.dir",
        "kind": "directory",
        "path": "memory",
        "on_missing": "create"
      },
      {
        "id": "memory.files.index",
        "kind": "file",
        "path": "memory/INDEX.md",
        "template": "templates/INDEX.md",
        "on_missing": "create",
        "on_existing": "preserve",
        "watch": true
      },
      {
        "id": "memory.files.inbox",
        "kind": "file",
        "path": "memory/INBOX.md",
        "template": "templates/INBOX.md",
        "on_missing": "create",
        "on_existing": "preserve",
        "watch": true
      }
    ],
    "context": [
      {
        "id": "memory.files.index",
        "event": "prompt.build.before",
        "source": {"kind": "file", "base": "workspace", "path": "memory/INDEX.md"},
        "title": "Memory Index",
        "priority": 80,
        "stability": "stable",
        "max_chars": 12000,
        "on_error": "warn"
      },
      {
        "id": "memory.files.inbox",
        "event": "prompt.build.before",
        "source": {"kind": "file", "base": "workspace", "path": "memory/INBOX.md"},
        "title": "Memory Inbox",
        "priority": 180,
        "stability": "volatile",
        "max_chars": 12000,
        "on_error": "warn"
      }
    ],
    "tools": [
      {
        "name": "memory__write",
        "module": "Nex.Agent.Plugin.MemoryFiles.WriteTool",
        "surfaces": ["all", "base"]
      },
      {
        "name": "memory__read",
        "module": "Nex.Agent.Plugin.MemoryFiles.ReadTool",
        "surfaces": ["all", "base", "follow_up", "subagent", "cron"]
      }
    ],
    "skills": [
      {
        "id": "builtin:memory-files",
        "path": "skills/memory-files/SKILL.md"
      }
    ]
  },
  "permissions": {
    "filesystem": {
      "read": ["workspace:memory/**"],
      "write": ["workspace:memory/**"]
    }
  }
}
```

This manifest depends on plugin primitives that do not exist yet. It is a target shape, not current implementation syntax.

## 验收心智

一个合格的 file memory plugin 应满足：

- 禁用插件后，`memory__write`、`memory__read`、memory skill、INDEX/INBOX prompt 注入都消失。
- 启用插件后，缺失的 `memory/INDEX.md` 和 `memory/INBOX.md` 被安全创建。
- `ContextBuilder` 不包含 `memory/MEMORY.md` 特例。
- 每轮 prompt 的 memory 部分来自 runtime snapshot context contributions。
- `INDEX.md` 和 `INBOX.md` 更新触发 runtime reload 或下一 turn context refresh。
- `memory__write` 只 append，不重写已有文件。
- `memory__read` 不能逃出 workspace `memory/`。
- 后台整理若启用，走 plugin queue/job，不走专用 `MemoryUpdater`。

## 开放问题

1. `memory__write` 是否应允许指定非 `INBOX.md` path，还是第一版强制只写 INBOX？
2. `memory__read` 是否包含 directory list，还是单独增加 `memory__list`？
3. 自动 capture after turn 是否第一版就做，还是只保留显式 `memory__write`？
4. 旧 `USER.md` 和新 file memory 的边界如何在 skill 中表达，避免用户偏好被写进 INBOX？
5. `INBOX.md` 变大后的截断策略是 newest-first、oldest-first，还是只注入 index + tail？
6. 旧 `MEMORY.md` 如何迁移：自动 create-only migration、owner-approved migration，还是人工整理？
7. Notice 行为是否保留为 memory plugin 自己的可选 user-visible output？
