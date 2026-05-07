# Hindsight Memory Plugin Integration

## 背景

[Hindsight](https://github.com/vectorize-io/hindsight) 是 Vectorize 开源/云端的 agent memory system。它的核心操作不是单纯的 vector search，而是：

- `retain`：把自然语言内容写入 memory bank，并抽取、分类、索引为可检索记忆。
- `recall`：用多策略检索从 memory bank 找相关记忆。
- `reflect`：基于记忆和 mental models 做综合回答。
- mental models：随记忆更新的 living documents，可按 bank/query/tags 维护。

官方 Hindsight Cloud 文档说明它通过 MCP 暴露 memory operations，并支持 single-bank / multi-bank 两种 MCP connection mode。single-bank endpoint 把 agent 固定到某个 bank；multi-bank endpoint 通过 `X-Bank-Id` 或 tool 参数选择 bank。Hindsight 的 best practices 也明确 memory bank 是用户、agent 或上下文之间的隔离单元。

本设计目标不是把 Hindsight 做成 NexAgent core memory backend，而是把它作为一个普通 memory plugin 接入。它应验证上一份插件系统设计里的通用 primitives：MCP client、secrets/auth、resources、dynamic context、events、queues/jobs、operation tracking、observability。

## 设计立场

### Hindsight 是 derived memory，不是 raw truth source

NexAgent 的原始对话事实仍应来自本地 session/event log、channel backfill contract、workspace files 和 ControlPlane。Hindsight 可以保存抽取后的 facts、observations、mental models、documents 和 recall indexes，但不应成为唯一真相源。

```text
NexAgent sessions / events / files / ControlPlane
  -> plugin jobs retain selected content into Hindsight
  -> Hindsight recall / reflect / mental models
  -> bounded context or tool results for LLM
```

原因：

- Hindsight `retain` 会把内容处理为结构化记忆，原文逐字保真不是它的核心 contract。
- recall/reflect 是 projection，可能受 bank mission、directives、tags、模型抽取质量影响。
- NexAgent 需要可重建、可审计、可迁移的本地长期协作语义。

### Plugin host 不知道 Hindsight

不新增 `hindsight` 专用 code path，也不新增 `memory` 专用 contribution kind。接入 Hindsight 所需的能力应是通用插件 primitives：

- `mcp_clients`
- `secrets`
- `resources`
- `context`
- `tools`
- `skills`
- `events`
- `queues`
- `scheduled_jobs`
- `services`
- `operations`
- `permissions`

Hindsight plugin 只是组合这些 primitives。

## Plugin 形态

插件 id 草案：

```text
builtin:memory.hindsight
```

它可以支持三种部署模式：

### 1. Hindsight Cloud MCP

连接官方 MCP endpoint。

```text
single-bank: https://api.hindsight.vectorize.io/mcp/{bank_id}/
multi-bank:  https://api.hindsight.vectorize.io/mcp
```

适合快速接入、云端管理、OAuth/API key。

### 2. Local Hindsight Service

由 NexAgent 插件 service 启动或连接本地 Hindsight Docker/API。

官方 GitHub quick start 暴露：

```text
API: http://localhost:8888
UI:  http://localhost:9999
```

适合本地优先、数据不出本机或团队内私有部署。

### 3. Direct REST Client

绕过 MCP，插件 wrapper tools 直接调 REST API。

适合需要更强控制、operation polling、bank bootstrap、custom auth 时使用。但第一版优先 MCP，因为这可以验证通用 MCP client contribution。

## 需要的插件 primitives

### MCP Client Contribution

Hindsight 最自然的接入方式是 MCP。插件系统需要支持 remote HTTP MCP client contribution：

```json
{
  "contributes": {
    "mcp_clients": [
      {
        "id": "hindsight.cloud",
        "transport": "http",
        "url": "https://api.hindsight.vectorize.io/mcp/{bank_id}/",
        "auth": {"type": "secret_header", "header": "Authorization", "secret": "hindsight.api_key", "prefix": "Bearer "},
        "tool_namespace": "hindsight",
        "surfaces": ["all", "base", "subagent"],
        "allow_tools": ["retain", "recall", "reflect", "get_mental_model", "list_mental_models", "list_operations", "get_operation"]
      }
    ]
  }
}
```

要求：

- MCP tools 经 ToolRegistry/ControlPlane 统一暴露和执行。
- tool namespace 可避免和本地工具重名，例如 `hindsight__recall`。
- 支持 tool allowlist，避免直接暴露 `delete_memory`、`clear_memories` 这类破坏性工具。
- MCP connection 状态进入 runtime diagnostics。
- MCP tool schema 变化触发 runtime reload 或工具 projection refresh。

### Secrets And Auth

插件不能把 API key 写在 manifest，也不能读取 `~/.nex/agent/config.json`。需要通用 secret reference：

```json
{
  "secrets": [
    {
      "id": "hindsight.api_key",
      "required": true,
      "env": "HINDSIGHT_API_KEY",
      "description": "Hindsight API key for cloud or private deployment."
    }
  ]
}
```

本地服务还可能需要：

```text
HINDSIGHT_API_LLM_API_KEY
HINDSIGHT_API_RETAIN_LLM_MODEL
HINDSIGHT_API_REFLECT_LLM_MODEL
```

Hindsight 支持 retain/reflect/consolidation 等 operation 使用不同 LLM 配置。NexAgent plugin config 不应复制 provider key 明文，而应声明 secret refs 和 model role mapping。

### Bank Scope Resolver

Hindsight bank 是隔离单元。NexAgent 必须明确 bank routing，否则跨 channel/project/user 会污染记忆。

草案：

```json
{
  "config": {
    "bank_routing": {
      "mode": "workspace",
      "template": "nex-{workspace_hash}",
      "fallback": "default"
    }
  }
}
```

候选 routing mode：

- `workspace`：一个 workspace 一个 bank。
- `user`：一个用户一个 bank。
- `project`：一个 active project 一个 bank。
- `channel_scope`：一个 channel instance + parent chat scope 一个 bank。
- `explicit`：配置固定 bank id。
- `multi_bank`：LLM/tool 根据 context 选择 bank，但必须有默认 bank。

第一版推荐：

```text
single-bank + workspace routing
```

原因：最少污染、最容易调试、和 workspace memory 语义一致。

### Resource Namespace

Hindsight plugin 应声明 resource namespace，供 read/list/debug UI 使用：

```text
hindsight://banks/{bank_id}/memories/{memory_id}
hindsight://banks/{bank_id}/mental-models/{model_id}
hindsight://banks/{bank_id}/operations/{operation_id}
```

这不是给 LLM 直接学数据库 API，而是给统一 `read` / future `resource_read` 能力提供稳定入口。MCP/REST 只是 backend。

### Dynamic Context Contribution

Hindsight 接入最有价值的地方不是把所有 recall 结果常驻，而是 request-time bounded recall/mental model injection。

候选 context fragments：

```text
Hindsight Bank Overview       stable / low cost
Selected Mental Models        stable-ish / medium cost
Recall For Current Turn       volatile / bounded / optional
```

草案：

```json
{
  "contributes": {
    "context": [
      {
        "id": "hindsight.mental-model.user",
        "event": "prompt.build.before",
        "source": {
          "kind": "mcp_tool",
          "client": "hindsight.cloud",
          "tool": "get_mental_model",
          "args": {"name": "workspace-current-context"}
        },
        "priority": 120,
        "stability": "stable",
        "max_chars": 8000,
        "ttl_seconds": 3600,
        "on_error": "skip"
      },
      {
        "id": "hindsight.recall.current-turn",
        "event": "prompt.build.before",
        "source": {
          "kind": "mcp_tool",
          "client": "hindsight.cloud",
          "tool": "recall",
          "args_from": "current_prompt_query"
        },
        "priority": 220,
        "stability": "volatile",
        "max_chars": 6000,
        "timeout_ms": 3000,
        "on_error": "skip"
      }
    ]
  }
}
```

第一版建议不要默认开启 dynamic recall。先暴露 explicit `hindsight__recall` tool 和 mental model context；等 latency/cost/quality 可观测后再考虑 auto recall。

### Queue, Jobs, And Operations

Hindsight retain 支持 sync/async，mental model create/refresh 返回 operation id。插件系统需要通用 operation tracking：

```text
operation_id
plugin_id
bank_id
kind
status
started_at
last_checked_at
result_summary
error_summary
```

Hindsight jobs：

#### Retain After Turn

触发：

```text
conversation.turn.finished
owner_run=true
from_cron=false
from_subagent=false
```

行为：

- 从 bounded turn summary / selected messages / tool outcome 中生成 retain item。
- 附带 metadata：workspace、session_key、channel、chat_id、run_id、timestamp、source pointer。
- queue coalesce by `{workspace, session_key}`。
- 默认 async retain 或低优先级 sync retain。

#### Refresh Mental Models

触发：

- retain 成功后，如果 Hindsight bank config 未自动 refresh。
- schedule。
- 用户显式要求刷新。

行为：

- 调 `refresh_mental_model`。
- 记录 operation id。
- 后台 poll `get_operation`。

#### Operation Poller

触发：

- operation created。
- schedule/queue retry。

行为：

- poll operation until terminal state。
- 写 ControlPlane。
- 必要时更新 plugin resource cache。

### Permissions

Hindsight plugin 权限必须明确：

```json
{
  "permissions": {
    "network": [
      "https://api.hindsight.vectorize.io",
      "http://127.0.0.1:8888"
    ],
    "secrets": ["hindsight.api_key"],
    "model_calls": {
      "external": true,
      "operations": ["retain", "reflect", "mental_model_refresh"]
    },
    "tools": {
      "exposes": ["hindsight__retain", "hindsight__recall", "hindsight__reflect"]
    }
  }
}
```

破坏性 MCP tools 默认不暴露：

```text
delete_memory
delete_document
delete_mental_model
clear_memories
delete_bank
```

如果未来要开放，必须 owner-approved 或 admin surface。

## LLM 可见能力

第一版推荐暴露少量 wrapper tools，而不是把 27/30 个 MCP tools 全扔给模型。

### `hindsight__retain`

用途：显式保存内容到 Hindsight。

输入：

```json
{
  "content": "The user prefers design discussions to start from first principles.",
  "context": "NexAgent memory architecture discussion",
  "tags": ["user:owner", "topic:memory"],
  "async": true
}
```

### `hindsight__recall`

用途：检索 raw memories。

输入：

```json
{
  "query": "What did we decide about plugin primitives for memory?",
  "budget": "mid",
  "max_tokens": 4000,
  "tags": ["topic:memory"]
}
```

### `hindsight__reflect`

用途：让 Hindsight 基于记忆综合回答。应比 recall 更谨慎使用，因为它会产生二次推理。

输入：

```json
{
  "query": "Summarize the current memory plugin design tradeoffs.",
  "context": "The user is deciding implementation order.",
  "budget": "low",
  "max_tokens": 2000
}
```

### `hindsight__mental_model`

用途：读取或刷新固定 mental model。第一版可只读。

## Skill 指导

Hindsight plugin 的 skill 应教 LLM：

```text
Use Hindsight when the user asks about prior long-horizon context, cross-session preferences, recurring patterns, or synthesized learning.

Use recall for source-like context. Use reflect only when the user asks for synthesis or when combining multiple memories is the task.

Do not treat Hindsight as the only source of truth. If exact wording, tool output, or a past decision needs verification, inspect NexAgent session logs, files, or ControlPlane.

Prefer retain for durable facts, user/project preferences, confirmed decisions, and reusable lessons. Do not retain one-off outputs or sensitive secrets.

Always include useful tags and source metadata when retaining.

Never use destructive Hindsight tools unless explicitly approved by the owner.
```

## Data Flow

### Explicit recall flow

```text
user asks about prior context
  -> LLM loads Hindsight skill
  -> call hindsight__recall
  -> if exactness matters, read local session/file source
  -> answer with source confidence
```

### Background retain flow

```text
owner turn finished
  -> event subscription enqueues retain candidate job
  -> job builds bounded retain item with source metadata
  -> Hindsight retain async
  -> operation tracked in ControlPlane
  -> no user-visible notice by default
```

### Mental model flow

```text
scheduled or explicit refresh
  -> refresh mental model
  -> operation id tracked
  -> future turns optionally inject selected model summary
```

## Observability

最低观测：

```text
plugin.hindsight.mcp.connected
plugin.hindsight.mcp.failed
hindsight.retain.queued
hindsight.retain.started
hindsight.retain.finished
hindsight.retain.failed
hindsight.recall.started
hindsight.recall.finished
hindsight.reflect.started
hindsight.reflect.finished
hindsight.operation.polled
hindsight.operation.finished
hindsight.context.injected
hindsight.context.skipped
```

Attrs 至少包括：

- `plugin_id`
- `bank_id`
- `operation`
- `operation_id`
- `workspace`
- `session_key`
- `run_id`
- `tags`
- `usage` summary when returned
- `result_count` for recall
- `latency_ms`
- `error_summary`

不要记录完整 retained content、完整 recall result、完整 reflect answer 到 ControlPlane attrs。需要原文时保存 source pointer。

## 成本与性能

Hindsight operation 有不同成本结构：

- recall 是检索，通常比 reflect 便宜。
- reflect 会做综合推理并返回 usage。
- retain 会做抽取和索引。
- mental model refresh 是后台生成。

NexAgent policy：

- 默认不在每个 prompt 前自动 recall。
- 默认 background retain coalesce/debounce。
- reflect 只由显式 tool call 或 skill 判断触发。
- context injection 优先 mental model，少用 volatile recall。
- 所有 Hindsight calls 进入 budget/ControlPlane。

## 安全与隐私

风险：

- 会话里可能包含密钥、私人信息、群聊隐私。
- Hindsight Cloud 会把 retained content 发到外部服务。
- recall/reflect 可能把旧的不相关隐私带回当前 channel。
- bank routing 错误会跨用户/项目污染。

默认策略：

- Cloud mode 必须显式启用。
- Retain job 需要 redaction/pass-through policy。
- group chat 默认不自动 retain，除非 channel scope 明确。
- subagent/cron 默认不自动 retain。
- bank routing 必须进入 runtime status/diagnostics。
- retention/deletion 工具默认 admin-only。

## Manifest 草案

```json
{
  "id": "builtin:memory.hindsight",
  "title": "Hindsight Memory",
  "version": "0.1.0",
  "enabled": false,
  "source": "builtin",
  "description": "Optional Hindsight-backed derived memory via MCP or local service.",
  "contributes": {
    "mcp_clients": [
      {
        "id": "hindsight",
        "transport": "http",
        "url": "https://api.hindsight.vectorize.io/mcp/{bank_id}/",
        "auth": {"type": "secret_header", "header": "Authorization", "secret": "hindsight.api_key", "prefix": "Bearer "},
        "tool_namespace": "hindsight",
        "allow_tools": ["retain", "recall", "reflect", "list_mental_models", "get_mental_model", "refresh_mental_model", "list_operations", "get_operation"],
        "surfaces": ["all", "base", "subagent"]
      }
    ],
    "tools": [
      {"name": "hindsight__retain", "adapter": "mcp:hindsight/retain", "surfaces": ["all", "base"]},
      {"name": "hindsight__recall", "adapter": "mcp:hindsight/recall", "surfaces": ["all", "base", "follow_up", "subagent"]},
      {"name": "hindsight__reflect", "adapter": "mcp:hindsight/reflect", "surfaces": ["all", "base"]}
    ],
    "skills": [
      {"id": "builtin:hindsight-memory", "path": "skills/hindsight-memory/SKILL.md"}
    ],
    "resources": [
      {"id": "hindsight", "scheme": "hindsight", "backend": "mcp", "client": "hindsight"}
    ],
    "queues": [
      {"id": "hindsight.retain", "concurrency": 1, "coalesce_by": ["workspace", "session_key"], "debounce_ms": 30000}
    ],
    "event_subscriptions": [
      {
        "id": "hindsight.retain-after-turn",
        "event": "conversation.turn.finished",
        "filter": {"owner_run": true, "from_cron": false, "from_subagent": false},
        "enqueue": {"queue": "hindsight.retain"}
      }
    ]
  },
  "config": {
    "bank_routing": {"mode": "workspace", "template": "nex-{workspace_hash}"},
    "auto_retain": false,
    "auto_recall": false
  },
  "secrets": [
    {"id": "hindsight.api_key", "env": "HINDSIGHT_API_KEY", "required": false}
  ],
  "permissions": {
    "network": ["https://api.hindsight.vectorize.io"],
    "secrets": ["hindsight.api_key"]
  }
}
```

This depends on plugin primitives that do not exist yet. It is a target integration shape.

## 实施顺序建议

1. 补插件系统 primitives：MCP client、secret refs、resources、operations。
2. 实现 Hindsight Cloud single-bank manual mode：
   - user config 固定 bank id
   - expose `hindsight__recall`
   - expose skill
   - no auto retain
3. 增加 `hindsight__retain` 和 source metadata/redaction。
4. 增加 operation tracking。
5. 增加 local service mode。
6. 增加 mental model read/inject。
7. 最后考虑 event-driven auto retain 和 dynamic recall context。

## 开放问题

1. Hindsight Cloud OAuth 如何和 NexAgent 非浏览器 gateway 场景对齐？第一版是否只支持 API key secret ref？
2. bank routing 是否应默认 workspace，还是 user/project 更符合个人 agent？
3. auto retain 是否需要 owner approval，还是 workspace config opt-in 即可？
4. recall result 是否应该缓存到本地 resource cache，避免频繁重复检索？
5. Hindsight mental model 是否应注入 system prompt，还是只在 skill/tool 调用后进入当前 turn？
6. local Hindsight service 是否由 NexAgent supervision 启动 Docker，还是只连接用户已启动服务？
7. destructive MCP tools 是否完全不暴露，还是放到 admin/maintenance surface？

## References

- [Hindsight GitHub](https://github.com/vectorize-io/hindsight)
- [Hindsight Cloud MCP Integration](https://docs.hindsight.vectorize.io/mcp/)
- [Hindsight Best Practices](https://hindsight.vectorize.io/best-practices)
- [Retain: Storing Memories](https://docs.hindsight.vectorize.io/retain/)
- [Recall: Retrieving Memories](https://docs.hindsight.vectorize.io/recall/)
- [Reflect: Reasoning Over Memories](https://docs.hindsight.vectorize.io/reflect/)
- [Create Mental Model API](https://docs.hindsight.vectorize.io/api-reference/create-mental-model/)
- [Hindsight Configuration](https://hindsight.vectorize.io/developer/configuration)
