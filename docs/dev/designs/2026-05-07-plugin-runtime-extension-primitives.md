# Plugin System And Hindsight Memory

## 一句话

插件不是一套新的 runtime。插件就是一个包，里面放技能、工具、hook、MCP 连接、后台任务、工作区文件模板和权限声明。

启用插件以后，这些东西进入 NexAgent 已有的主链：

```text
插件包
  -> Runtime.Snapshot
  -> hooks / ToolRegistry / Skills / PermissionRule / ControlPlane
  -> Runner 每轮使用
```

最终方案的判断标准不是“尽量少改现有代码”，而是改完以后每件事只有一个自然入口：

- prompt 里多放东西，走 hook。
- 模型能调用什么，走 ToolRegistry。
- 工具能不能真的执行，走权限规则。
- 后台维护工作，走 runtime job。
- 运行事实和失败原因，走 ControlPlane。
- 插件自己的文件，仍然是 workspace 里的普通文件。

## 为什么要重写

旧设计把同一件事拆成了太多名字，比如 `context`、`resources`、`primitives`。这些词让设计看起来很通用，但读起来像在发明一个平行系统。

现在收口成更直接的说法：

- 不再把 `context` 当插件贡献类型。插件想给 prompt 加内容，就声明 hook。
- 不再把 `resources` 当插件顶层概念。文件就是 workspace 文件；外部对象通过工具或 MCP 读写。
- 不再把 `allowed_tools` 当权限。它最多表示“这轮给模型看哪些工具”；真正的 allow/ask/deny 归权限规则。
- 不新增 memory 专用插件接口。Hindsight 是必接的 memory 插件，但它仍然通过 hook、tool、MCP、job、权限这些通用主链接入。

## 最终心智模型

### Plugin

插件是安装、启用、禁用、诊断和升级的单位。

一个插件可以带这些东西：

- `skills`：教 agent 什么时候用、怎么用。
- `tools`：模型可调用的确定性能力。
- `hooks`：在某个 runtime 时刻自动做事，比如 prompt 构建前加记忆。
- `mcpServers`：外部 MCP 服务，例如 Hindsight。
- `jobs`：后台任务，例如一轮对话结束后把摘要写入 Hindsight。
- `workspaceFiles`：插件需要的 workspace 文件或目录，例如 `memory/hindsight/status.json`。
- `permissions`：插件需要哪些网络、文件、工具调用权限。

插件不拥有一套独立世界观。长期进程看的还是 `Runtime.Snapshot`。

### Hook

hook 是“什么时候做什么”。

当前代码已经有 `prompt.build.before`，Runner 会在构建初始消息前执行 hook，然后把结果交给 ContextBuilder 拼进 system prompt。这个方向是对的，只是能力不够完整。

目标状态：

- workspace 自己写的 `hooks/hooks.json` 继续有效。
- enabled plugins 也可以贡献 hooks。
- runtime 把两边合并成 snapshot 里的有效 hook 列表。
- Runner 每轮按事件和当前会话信息执行匹配的 hook。

插件注入 prompt 的正确做法就是：

```text
prompt.build.before hook
  -> 读文件，或调用工具，或拿到 MCP 返回
  -> 生成一段有标题、有来源、有长度限制的 prompt 内容
  -> ContextBuilder 只负责排版
```

ContextBuilder 不应该知道 Hindsight，也不应该硬编码 `memory/MEMORY.md`。

### Tool

tool 是模型能看到并请求调用的能力。

工具来源可以不同：

- core module
- builtin plugin module
- MCP server tool
- 受控的外部进程

但进入模型和执行时都应该走同一条 ToolRegistry 主链。

目标状态：

```text
plugin tool declaration
  -> ToolRegistry definition
  -> Runner 暴露给模型
  -> 模型请求 tool call
  -> PermissionRule 判断
  -> ToolRegistry 执行 module 或 MCP tool
  -> ControlPlane 记录
```

### Permission

权限系统回答的是：这次具体动作能不能发生。

这和“模型这轮能看见哪些工具”不是一回事。

最终设计里，所有实际动作都应该变成权限事件：

- 读文件
- 写文件
- 发网络请求
- 调 MCP tool
- 启动进程
- 后台 job 调工具
- hook 调工具
- channel 上传文件或发消息

权限规则统一给出 `allow`、`ask`、`deny`。如果现有 `tool_allowlist`、skill frontmatter 里的 `allowed_tools`、插件里的工具声明和权限系统打架，就改掉这些名字或职责，而不是新增一个并存的权限层。

建议最终命名：

- `tool_surfaces`：工具可出现在哪些运行面，例如 owner turn、follow-up、subagent、cron。
- `visible_tools` 或 `tool_scope`：某一轮 LLM 可以看到哪些工具。
- `permissions`：实际执行时的 allow/ask/deny。

### Workspace Files

插件需要的可读写路径就是 workspace 文件，不叫 `resources`。

插件声明这些文件的目的只是：

- 首次启用时创建目录或模板。
- runtime 知道哪些文件变化会影响 prompt 或后台任务。
- diagnostics 能说明缺文件、不可读、不可写。
- 禁用或卸载插件时不误删用户数据。

例子：

```json
{
  "contributes": {
    "workspaceFiles": [
      {
        "id": "hindsight.status",
        "path": "memory/hindsight/status.json",
        "kind": "file",
        "onMissing": "create",
        "watch": true
      }
    ]
  }
}
```

这和“workspace artifact”没有本质区别。它就是插件声明自己会用到的 workspace artifact。

如果 Hindsight 或 MCP 里有自己的外部对象，比如 bank、memory id、operation id，它们不进入 Nex 插件顶层概念。需要读就通过 `hindsight__recall`、`hindsight__operation_status` 这类工具读。

### Background Job

后台任务是插件在用户不直接发话时做维护工作的方式。

Hindsight 必须有后台任务，因为 memory retain 不应该全靠模型每次手动想起来：

```text
conversation.turn.finished hook
  -> enqueue hindsight.retain job
  -> job 调 hindsight__retain
  -> 权限规则判断
  -> 写 ControlPlane
```

job 默认不对用户发消息。它只维护 runtime 状态，除非插件明确声明某个结果应该投递到 channel。

## Hindsight 插件 demo

这是目标形态，当前代码要改到能吃这个形状。

```json
{
  "id": "builtin:memory.hindsight",
  "title": "Hindsight Memory",
  "version": "1.0.0",
  "enabled": true,
  "source": "builtin",
  "description": "Required memory plugin backed by Hindsight.",
  "config": {
    "mcp_url": "http://localhost:8888/mcp/",
    "bank_id": "nex-{{workspace.hash}}",
    "authorization_header": ""
  },
  "contributes": {
    "mcpServers": [
      {
        "id": "hindsight",
        "transport": "streamable-http",
        "url": "{{plugin.config.mcp_url}}",
        "headers": {
          "Authorization": "{{plugin.config.authorization_header}}"
        },
        "toolPrefix": "hindsight__"
      }
    ],
    "tools": [
      {
        "name": "hindsight__recall",
        "from": "mcp:hindsight/recall",
        "surfaces": ["owner", "follow_up", "subagent", "cron"]
      },
      {
        "name": "hindsight__retain",
        "from": "mcp:hindsight/retain",
        "surfaces": ["owner", "cron"]
      },
      {
        "name": "hindsight__mental_model",
        "from": "mcp:hindsight/get_mental_model",
        "surfaces": ["owner", "follow_up", "subagent", "cron"]
      },
      {
        "name": "hindsight__operation_status",
        "from": "mcp:hindsight/get_operation",
        "surfaces": ["owner", "cron"]
      }
    ],
    "skills": [
      {
        "id": "builtin:hindsight-memory",
        "path": "skills/hindsight-memory/SKILL.md"
      }
    ],
    "hooks": [
      {
        "id": "hindsight.prompt.memory",
        "event": "prompt.build.before",
        "action": {
          "type": "add_tool_result",
          "tool": "hindsight__recall",
          "args": {
            "bank": "{{workspace.hindsight_bank}}",
            "query": "{{turn.prompt}}",
            "session": "{{session.key}}",
            "limit": 8
          },
          "title": "Hindsight Memory",
          "maxChars": 8000,
          "onError": "warn"
        }
      },
      {
        "id": "hindsight.after_turn.retain",
        "event": "conversation.turn.finished",
        "action": {
          "type": "enqueue_job",
          "job": "hindsight.retain",
          "coalesceBy": ["workspace", "session_key"]
        }
      }
    ],
    "jobs": [
      {
        "id": "hindsight.retain",
        "run": {
          "tool": "hindsight__retain",
          "args": {
            "bank": "{{workspace.hindsight_bank}}",
            "content": "{{turn.summary}}",
            "source": "{{turn.source_pointer}}"
          }
        }
      }
    ],
    "workspaceFiles": [
      {
        "id": "hindsight.status",
        "path": "memory/hindsight/status.json",
        "kind": "file",
        "onMissing": "create",
        "watch": true
      }
    ]
  },
  "permissions": [
    {
      "effect": "ask",
      "resource": "network",
      "operation": "connect",
      "target": "hindsight endpoint",
      "scope": "workspace"
    },
    {
      "effect": "ask",
      "resource": "tool",
      "operation": "call",
      "target": "hindsight__retain",
      "scope": "workspace"
    },
    {
      "effect": "ask",
      "resource": "filesystem",
      "operation": "write",
      "target": "workspace:memory/hindsight/**",
      "scope": "workspace"
    }
  ]
}
```

关键点：

- Hindsight 是默认必须接入的 memory 能力。
- 本地文件可以作为状态、缓存、导出或人工可读备份，但不是 Hindsight 的替代主线。
- prompt 注入通过 `prompt.build.before` hook 完成。
- 自动保存通过 `conversation.turn.finished` hook 加后台 job 完成。
- MCP tool 进入 ToolRegistry，不给 Hindsight 单独开后门。
- 权限声明只描述需求，真正执行仍由 PermissionRule 判断。

## 一次对话怎么跑

### 启动或热更新

```text
读取 config
读取 enabled plugins
校验插件声明
合并插件 hooks/tools/skills/jobs/workspaceFiles/permissions
生成 Runtime.Snapshot
刷新 ToolRegistry
启动或连接 Hindsight MCP
更新 watcher 路径
```

### 用户发来一轮消息

```text
InboundWorker 找到 session
Runner 准备 turn
Runner 执行 prompt.build.before hooks
Hindsight hook 调 hindsight__recall
权限规则判断 recall 是否允许
ToolRegistry 调 MCP
Hook 把结果变成 prompt 片段
ContextBuilder 只负责排版
LLM 正常回答
```

### 一轮结束

```text
Runner 发 conversation.turn.finished event
Hindsight retain hook enqueue job
job 调 hindsight__retain
权限规则判断 retain 是否允许
Hindsight 返回 operation id
ControlPlane 记录 job 和 operation
后续 job 查询 operation 状态
```

## 现有代码应该怎么改

### Hook 主链要升级

当前锚点：

- `lib/nex/agent/capability/hooks.ex`
- `lib/nex/agent/turn/runner.ex`
- `lib/nex/agent/turn/context_builder.ex`

目标变化：

- `Hooks.load/1` 不只读 workspace `hooks/hooks.json`，还要吃 enabled plugins 的 hook 声明。
- hook entry 带 `source`，能知道来自 workspace 还是某个 plugin。
- `prompt.build.before` 支持 `add_text`、`add_file`、`add_tool_result`。
- 增加 `conversation.turn.finished` 这类 lifecycle event。
- hook 执行工具时必须走 ToolRegistry 和 PermissionRule。

### ContextBuilder 要瘦身

当前 `ContextBuilder` 还硬编码 memory 文件。目标是删掉这种业务读取。

它保留：

- identity/runtime/channel 元信息排版。
- hook 结果排版。
- skills catalog 排版。
- diagnostics。

它不再直接知道：

- `memory/MEMORY.md`
- Hindsight
- file memory
- 哪个插件应该给 prompt 加什么

### ToolRegistry 要成为唯一工具入口

当前 ToolRegistry 已经能从 plugin tools 生成 definitions 和执行表。目标是继续扩它，而不是给 MCP 开旁路。

目标变化：

- tool declaration 支持 `from: "module:..."` 和 `from: "mcp:server/tool"`。
- MCP tool 名字统一变成 provider-safe 名字，例如 `hindsight__recall`。
- ToolRegistry 执行任何 tool 前都能构造权限事件。
- disabled plugin 的 tool 不出现在 definitions，也不能直接执行。

### 权限系统要统一执行判断

当前 `PermissionRule` 已经是正确方向。要补的是覆盖面。

目标变化：

- tool call、MCP call、hook tool call、job tool call 都生成同一种 raw permission event。
- 插件 manifest 的 `permissions` 编译成 diagnostics 和可建议的规则，不成为独立判定器。
- `tool_allowlist` 这类运行参数只保留“可见工具范围”的职责，或改名成更准确的 `visible_tools` / `tool_scope`。
- skill 的 `allowed_tools` 也不当权限，只当技能建议的工具范围。

### Watcher 不能硬编码业务文件

当前 watcher 直接 watch `memory/MEMORY.md`。目标是由 runtime projection 生成 watch paths。

来源包括：

- workspace `hooks/hooks.json`
- plugin manifests
- plugin hook 读取的文件
- plugin workspaceFiles
- plugin skill files
- MCP/tool schema cache 文件，如果有

### 后台 job 是 runtime 能力

Hindsight retain、operation polling、mental model refresh 都不应该变成 `MemoryUpdater` 这种 memory 专用 worker。

目标变化：

- runtime 有一个通用 job runner。
- plugin hook 可以 enqueue job。
- job 可以直接调工具，也可以运行受限 LLM workflow。
- job 的 tool scope、权限、超时、重试、取消、观测都走统一主链。

### ControlPlane 记录机器真相

插件基础生命周期由 host 自动记：

- plugin loaded / disabled / diagnostics
- hook matched / skipped / injected
- tool available / called / failed
- job queued / started / finished / failed
- MCP connected / failed
- permission asked / denied / allowed

Hindsight 自己可以额外记录：

- retain queued / finished / failed
- recall result count
- operation status
- bank id
- latency

不要把完整 retained content、完整 recall result、完整 prompt 或完整 tool output 塞进 ControlPlane attrs。需要追原文时存 source pointer。

## 和外部系统的对齐

这个设计有意贴近 Claude Code、Codex、OpenClaw 的朴素模型：

```text
plugin = package
package can include skills + hooks + MCP + tools + config/assets
```

NexAgent 的不同点是它是长期运行的个人 agent runtime，所以还需要：

- session 和 workspace 语义。
- 后台 job。
- 热更新 snapshot。
- 权限规则。
- ControlPlane。

这些不是插件使用者要理解的新名词，而是 runtime 内部保证长期可靠性的主链。

## 判断一个改动是否走偏

如果出现下面情况，说明设计又复杂化了：

- 插件为了注入 prompt 新增了 hook 之外的入口。
- MCP tool 绕过 ToolRegistry 执行。
- 插件自己维护一套 allow/deny。
- 文件路径被包装成新的抽象对象。
- Hindsight 接入写了 memory 专用 runtime 分支。
- 后台 retain 变成某个 memory-only GenServer。
- diagnostics 只在日志里，ControlPlane 查不到。
- 禁用插件后工具还可见或可执行。
- 同一个权限问题同时由 `allowed_tools` 和 PermissionRule 判断。

最终应该读起来很直：插件包声明东西，runtime 合并，hook 加 prompt，tool 做动作，permission 管能不能做，job 做后台维护，ControlPlane 记事实。
