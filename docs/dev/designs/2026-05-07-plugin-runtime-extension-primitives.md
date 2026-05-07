# Plugin Runtime Extension Primitives

## 背景

Phase 20 已经把 channel、provider、tool、skill、command 迁移到 plugin contribution，但这仍然只是第一层插件化。它解决了“能力清单从哪里来”，还没有解决“一个插件如何像长期 runtime 的一部分一样工作”。

新的记忆系统讨论暴露了这个缺口：如果把 memory 做成一个普通插件，而不是 core 里的特殊 subsystem，插件系统必须提供足够通用的 runtime extension primitives。memory plugin 只是这些 primitives 的一个组合，不应该推动新增 `memory` 专用 contribution kind。

当前实现里，`ContextBuilder` 仍然直接读取 `memory/MEMORY.md`，`Runtime.Watcher` 直接 watch 该路径，`MemoryUpdater` 是 hardcoded background worker。这些都是 memory 还没有普通插件化的证据。后续改造目标不是把这些特例换成另一个 memory interface，而是把通用能力补齐，让 memory、notes、tasks、permission rules、Workbench apps、external services 都能使用同一套机制。

## 设计原则

### 插件系统不认识业务语义

Plugin host 不应该知道 memory、notes、task、workflow 这些业务概念。它只认识：

- 插件 manifest、启停、诊断和 runtime projection。
- 插件贡献的 workspace artifacts、context fragments、tools、skills、commands、resources、services、events、queues、jobs、permissions、migrations。
- 这些贡献如何进入 `Runtime.Snapshot`，如何热更新，如何观测，如何受安全边界约束。

如果未来出现 `builtin:memory.files`、`builtin:notes.local`、`workspace:mem0`，它们都应是普通插件。

### Runtime.Snapshot 仍是世界观

插件 manifest 和插件本地文件不是长期进程的运行时真相源。长期进程消费的仍是 `Runtime.Snapshot`：

```text
config + workspace + plugin manifests
  -> normalized plugin contributions
  -> runtime snapshot projections
  -> Runner / Gateway / ToolRegistry / ContextBuilder / Workbench / ControlPlane
```

插件贡献变化必须触发 runtime reload，更新 snapshot hash/version，再由现有长期进程 reconcile 或在下一 turn 读取新 snapshot。

### ContextBuilder 降级为 renderer

`ContextBuilder` 不应该硬编码读 `memory/MEMORY.md`。它的职责应该收窄为：

- 渲染 runtime identity / request metadata / channel format prompt。
- 渲染 runtime snapshot 里的 context fragments。
- 按 priority、stability、budget、pointcut 选择和排序。
- 产生 diagnostics。

哪些文件、哪些文本、哪些动态资源进入 system prompt，由插件贡献的 context fragments 决定。

### 热更新能力要复用

新增插件能力必须接入现有 runtime reload/watch 方向，而不是在每个 consumer 里手写 watcher。插件 manifest、插件声明的 workspace artifacts、context source、service config、queue/job config 变化，都应能投影到 snapshot hash 或对应 runtime component hash。

## 需要补齐的通用 primitives

### 1. Workspace Artifacts

插件需要声明自己拥有或初始化哪些 workspace 文件/目录。

用途：

- 首次启用插件时创建必要目录和模板文件。
- runtime diagnostics 能报告缺失、损坏、不可写。
- watcher 能知道哪些 plugin-owned artifacts 会影响 runtime prompt 或后台任务。
- 插件卸载/禁用时不误删用户数据。

草案 shape：

```json
{
  "contributes": {
    "workspace_artifacts": [
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
        "id": "memory.files.dir",
        "kind": "directory",
        "path": "memory",
        "on_missing": "create"
      }
    ]
  }
}
```

约束：

- `path` 默认相对 workspace。
- template 只能来自插件目录内的 artifact。
- `on_existing=preserve` 是默认值。
- 不允许插件默认覆盖用户编辑。
- 删除插件不删除 workspace artifacts，除非未来有明确 owner-approved cleanup flow。

### 2. Context Contributions

插件需要声明 prompt context fragment，替代硬编码 bootstrap 文件和 `memory/MEMORY.md` 读取。

草案 shape：

```json
{
  "contributes": {
    "context": [
      {
        "id": "memory.files.index",
        "event": "prompt.build.before",
        "pointcut": {"workspace": "*"},
        "source": {
          "kind": "file",
          "path": "memory/INDEX.md",
          "base": "workspace"
        },
        "title": "Memory Index",
        "priority": 80,
        "stability": "stable",
        "max_chars": 12000,
        "on_error": "warn"
      }
    ]
  }
}
```

需要支持的 source kind：

- `file`：读取 workspace/plugin/project 内文件。
- `text`：manifest 内短文本。
- `resource`：读取插件声明的 resource namespace。
- `module` 或 `service`：仅 builtin/reviewed plugin 可用，后续再冻结。

需要支持的投影属性：

- `priority`：越小越早注入。
- `stability`：`stable | volatile`，供 ContextBuilder 排序和 cache 友好布局。
- `max_chars` 和 total budget。
- `cache_key` 或 content hash。
- `pointcut`：workspace、session、channel、chat_id、parent_chat_id、surface。
- `on_error`：`skip | warn | block`。

现有 hooks 系统可作为起点，但它现在是 workspace-local registry，不是 plugin contribution，且只支持 `file/text` 和一个 event。后续应把 hooks 升级为 context contribution consumer，而不是让插件去改 `workspace/hooks/hooks.json`。

### 3. LLM-Facing Capabilities

插件需要以普通贡献暴露模型可见能力：

- `tools`
- `skills`
- `commands`
- `resources`

现有 tools/skills/commands 已有一部分基础，但还不完整：

- builtin plugin tool 可以引用 compiled module。
- workspace/project plugin 还不能安全贡献 executable tool。
- skill 已适合教 LLM 怎么使用插件。
- resource namespace 还没有独立 contribution。

`resources` 的目标不是 memory 专用 URI，而是通用命名空间：

```json
{
  "contributes": {
    "resources": [
      {
        "id": "memory.files",
        "scheme": "memory",
        "backend": "workspace_files",
        "root": "memory",
        "read": true,
        "write": false
      }
    ]
  }
}
```

`read` / `find` / future resource tools 可以通过 resource registry 解析 `memory://INDEX.md`、`notes://daily/2026-05-07.md` 等。底层可以是文件、SQLite、HTTP、MCP、service。

### 4. Runtime Services

插件可能需要长期进程，不只是被动 tool。

草案 shape：

```json
{
  "contributes": {
    "services": [
      {
        "id": "memory.files.indexer",
        "kind": "supervised_module",
        "module": "Nex.Agent.Plugin.MemoryFiles.Indexer",
        "restart": "permanent",
        "source": "builtin",
        "health_check": "status"
      }
    ]
  }
}
```

第一版约束：

- builtin plugin 可声明 compiled module service。
- workspace/project plugin 不加载任意 VM code。
- workspace/project plugin 可先声明 `external_process`、`mcp_server`、`http_service` 这类 data-configured service，但需要单独安全设计。
- service lifecycle 必须由 runtime supervision 管理，不能由 tool 调用偷偷起长期进程。

### 5. Runtime Events

插件需要订阅通用 runtime events，而不是让 core 在 memory path 写调用点。

候选事件：

```text
runtime.started
runtime.reloaded
plugin.enabled
plugin.disabled
workspace.opened
conversation.turn.started
conversation.turn.finished
conversation.session.idle
tool.call.started
tool.call.finished
file.changed
queue.job.finished
schedule.tick
```

草案 shape：

```json
{
  "contributes": {
    "event_subscriptions": [
      {
        "id": "memory.files.capture-after-turn",
        "event": "conversation.turn.finished",
        "filter": {"owner_run": true, "from_cron": false, "from_subagent": false},
        "enqueue": {
          "queue": "memory.files.capture",
          "coalesce_key": ["workspace", "session_key"],
          "debounce_ms": 30000
        }
      }
    ]
  }
}
```

Event payload 必须 bounded，不包含完整 prompt、完整 tool output、完整 provider response 或敏感原文。插件若需要原始会话，应通过受权限约束的 session/resource read 能力读取。

### 6. Queues, Jobs, And Schedules

插件需要后台工作能力。Cron 当前偏用户任务：它把 job 转为 inbound cron message，让 LLM 处理并决定是否发消息。这不适合 plugin internal maintenance。

需要新增通用 queue/job primitive：

```json
{
  "contributes": {
    "queues": [
      {
        "id": "memory.files.organize",
        "concurrency": 1,
        "coalesce_by": ["workspace"],
        "debounce_ms": 30000,
        "retry": {"max": 3, "backoff": "exponential"},
        "budget": {"model_calls": 1, "max_tokens": 20000}
      }
    ],
    "scheduled_jobs": [
      {
        "id": "memory.files.organize.daily",
        "schedule": {"type": "cron", "expr": "0 4 * * *"},
        "queue": "memory.files.organize",
        "enabled": true
      }
    ]
  }
}
```

Job handler options：

- `tool`：执行一个 plugin/core tool，适合 data-only plugin。
- `module`：builtin/reviewed plugin compiled module。
- `workflow`：用 LLM turn 执行，但必须声明 tools surface、model role、budget、visibility。
- `external_process` / `mcp`：后续设计。

关键要求：

- queue state 是 workspace-scoped 或 plugin-scoped durable state。
- 支持 coalescing，避免每轮消息都触发昂贵整理。
- 支持 cancellation 和 timeout。
- 所有 job lifecycle 写 ControlPlane。
- job 不默认 user-visible；显式声明 delivery 才能发消息。

### 7. Permissions

插件必须声明自己和它贡献能力的权限边界。

草案 shape：

```json
{
  "permissions": {
    "filesystem": {
      "read": ["workspace:memory/**"],
      "write": ["workspace:memory/**"]
    },
    "network": [],
    "model_calls": {
      "foreground": false,
      "background": true,
      "roles": ["cheap_model", "memory_model"]
    },
    "tools": {
      "uses": ["read", "find", "apply_patch"]
    }
  }
}
```

权限不是 Workbench grant，也不是 bash approval rule 的替代。它是插件 manifest 的最小声明，用于 diagnostics、runtime policy projection、tool/job/service 执行前检查。

### 8. Observability

插件 host 应自动产生基础观测：

```text
plugin.loaded
plugin.disabled
plugin.context.injected
plugin.context.skipped
plugin.tool.available
plugin.tool.called
plugin.queue.job.queued
plugin.queue.job.started
plugin.queue.job.finished
plugin.queue.job.failed
plugin.artifact.changed
plugin.service.started
plugin.service.failed
plugin.migration.applied
```

业务插件可以额外写语义 observations，例如 memory 插件可写 `memory.files.write.appended`，但基础生命周期不能靠业务插件自己补。

### 9. Migrations

插件会演化自己的 workspace structure，需要通用 migration 机制。

草案 shape：

```json
{
  "contributes": {
    "migrations": [
      {
        "id": "memory.files.v1",
        "from": null,
        "to": "1",
        "mode": "workspace_artifacts",
        "description": "Create memory/INDEX.md and memory/INBOX.md if missing."
      }
    ]
  }
}
```

要求：

- dry-run 和 apply 分离。
- apply 产生 backup 或 reversible operation summary。
- 不覆盖用户内容。
- 迁移结果写 ControlPlane。
- 结构性迁移默认 owner-approved，除非 manifest 声明为 safe create-only。

## Runtime Build 草案

目标 build order：

```text
load config
resolve workspace
load plugin manifests and enablement
normalize plugin contributions
apply safe workspace artifact checks/projections
build services/queues/schedules projection
build commands/tools/skills/resources projection
build context contribution projection
build prompt from context renderer
build workbench projection
assemble Runtime.Snapshot
```

重要变化：

- prompt build 不再自己读 memory。
- hooks/context contributions 先进入 snapshot，再由 Runner 在每次 turn 结合 pointcut 和 request ctx 选择。
- watcher 不再硬编码每个业务文件；它从 plugin artifacts/context source 生成 watch paths。
- plugin hash 不只包含 manifest，还应包含影响 runtime behavior 的 contribution projection hash。

## 与现有系统的关系

### 可以复用

- `Plugin.Manifest/Store/Catalog/Contribution` 的 manifest load 和 enablement。
- `Runtime.Snapshot.plugins` 的统一投影方向。
- `Tool.Registry` 从 plugin tools 派生 definitions/execution map。
- `Skills.Catalog` progressive disclosure。
- `Runtime.Watcher` 的 polling reload 模型。
- `Hooks` 的 fragment rendering、pointcut、on_error、observability 思路。
- `Cron` 的 schedule parser 和 per-workspace durable state 思路。

### 需要弱化或迁移

- `ContextBuilder.add_memory_with_diagnostics/2` 应被 context contribution 取代。
- `Runtime.Watcher.@workspace_files` 里的业务路径应转为 contribution-derived watch paths。
- `MemoryUpdater` 应作为 old memory plugin 的内部 worker 或被 queue/job primitive 取代。
- `workspace/hooks/hooks.json` 应成为 user-authored hook registry，而不是 plugin 安装默认 context 的唯一方式。

## 非目标

- 不新增 memory 专用 plugin kind。
- 不允许 workspace/project plugin 直接加载任意 Elixir module。
- 不把 Runtime、Runner、ToolRegistry、ContextBuilder、ControlPlane 整体变成可卸载插件。
- 不让插件绕过 sandbox、permission、runtime snapshot、ControlPlane。
- 不要求所有能力第一版都支持 workspace/project plugin；可以先支持 builtin plugin 和 data-only artifact plugin。

## 开放问题

1. Context contribution 是否应作为 `hooks` 的扩展，还是拆成 `context` 独立 contribution？
2. `resources` namespace 是否应先只支持 read/list/find，再支持 write？
3. Plugin queue job 的 handler 第一版是否只允许 builtin module 和 tool invocation？
4. Plugin migrations 的 owner approval UI 放在 Workbench、slash command，还是 deterministic tool？
5. Bootstrap 层 `AGENTS.md`、`IDENTITY.md`、`SOUL.md`、`USER.md` 是否也应迁移为不可卸载 builtin bootstrap plugin 的 context contributions？
6. Context fragments 的 cache stability 如何投影给不同 provider？第一版可能只排序，不做 provider-specific cache control。
