# Phase 23 Plugin External Service Foundation

## 当前状态

Phase 22 已经让 plugin 可以贡献 `hooks`、`jobs`、`workspaceFiles`、`mcpServers`，并把 module-backed tool、MCP-backed tool、workspace file bootstrap、turn-finished hook/job 串进 runtime 主链。

但要接入 Hindsight 这类外部 memory service，当前底座仍不够：

- MCP client 只有 stdio 形态，plugin MCP server 只认 `command`，不能直接连接 Hindsight Cloud/local HTTP endpoint。
- `Nex.Agent.Interface.MCP` 把 stdio process lifecycle、JSON-RPC request/response、tool cache 混在一个 GenServer 里，后续加 HTTP 很容易复制一套 MCP 调用逻辑。
- plugin template 只有少量 `{{turn.prompt}}`、`{{workspace.root}}` 变量，不能引用 plugin 自己的 config、secret、workspace/user 派生 bank id。
- 当前没有单独的 secret truth source；敏感配置如果直接进入 manifest/config/template，会被 snapshot、diagnostics、ControlPlane 或日志误打印。
- `PluginJobRunner` 是 hook-triggered one-shot queue；`Cron` 是另一套持久 schedule 系统。继续分别扩展会形成两套 task/job 抽象。
- Hindsight/Codex/Claude Code 的公开集成显示核心 memory loop 是 event hook first：prompt 前 recall，turn/session 后 retain；没有证据需要先做复杂 operation polling worker。
- 当前对外 surface 也已经分裂：Workbench HTTP 暴露 `scheduled-tasks`，bridge 暴露 `tasks.scheduled.*`，plugin manifest 暴露 `jobs`，内部则是 `Cron` / `PluginJobRunner`。这些名字如果目标态要删除，Phase 23 开工时就必须删除或改名，不能加过渡兼容入口。

本 phase 只补通用外部服务底座，不实现 Hindsight 插件本体，不新增 memory 专用接口。

## 完成后必须达到的结果

1. MCP client 拆成统一 protocol API + transport adapter：
   - stdio 继续可用。
   - streamable HTTP 可用。
   - `ServerManager`、`ToolRegistry`、plugin runtime 不感知底层 transport 差异。
2. plugin `mcpServers` 支持 streamable HTTP 声明，至少支持：
   - `transport: "streamable-http"`
   - `url`
   - `headers`
   - optional `timeout_ms`
3. streamable HTTP MCP client 满足最小官方 contract：
   - `POST` 发送 JSON-RPC 到单一 MCP endpoint。
   - request `Accept` 包含 `application/json, text/event-stream`。
   - 支持 `application/json` response。
   - 支持 POST response 返回 `text/event-stream`，能读到目标 JSON-RPC response。
   - 初始化后若收到 `Mcp-Session-Id` / `MCP-Session-Id`，后续请求必须带回。
   - GET SSE listener 本 phase 可以不保持长连接；如果实现，必须不影响 request/response 主路径。
4. plugin template 统一使用 `{{...}}` 语法；不引入 `${...}`。
5. template 支持 plugin config、workspace/session/turn/channel 变量，以及稳定 bank template 所需变量；plugin service credentials 走普通 plugin config。
6. 对外只暴露 Task：Workbench/API/plugin manifest/runtime docs 不再暴露 Cron、ScheduledTask、PluginJob、job queue。
7. 本 phase 只冻结并实现最小 queue policy：
   - `debounce_key`
   - `debounce_ms`
   - `max_runs`
8. 不实现 operation polling DSL；外部服务如果需要 operation status，先通过普通 tool 显式查询或后续 phase 再扩展通用 task continuation。
9. 用 fake external memory plugin / fake streamable HTTP MCP server 做验收，证明：
    - prompt 前 recall hook 可通过 HTTP MCP tool 注入 context。
    - turn-finished retain task 可 debounce 合并。
    - plugin config header + bank template 能渲染到 HTTP header/body，空 header 会被省略。
    - disabled plugin 后 HTTP MCP tool 不可见也不可执行。
    - secret 不在 snapshot/diagnostics/ControlPlane/log 中明文出现。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/designs/2026-05-07-plugin-runtime-extension-primitives.md`
- `docs/dev/designs/2026-05-07-hindsight-memory-plugin.md`
- `docs/dev/findings/2026-04-29-plugin-runtime-boundary.md`
- `docs/dev/task-plan/phase20-plugin-runtime-foundation.md`
- `docs/dev/task-plan/phase21-command-sandbox-and-approval.md`
- `docs/dev/task-plan/phase22-plugin-runtime-primitives.md`
- `lib/nex/agent/interface/mcp.ex`
- `lib/nex/agent/interface/mcp/server_manager.ex`
- `lib/nex/agent/capability/tool/registry.ex`
- `lib/nex/agent/capability/hooks.ex`
- `lib/nex/agent/capability/cron.ex`
- `lib/nex/agent/interface/workbench/scheduled_tasks.ex`
- `lib/nex/agent/runtime/plugin_job_runner.ex`
- `lib/nex/agent/runtime/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/extension/plugin/manifest.ex`
- `lib/nex/agent/extension/plugin/contribution.ex`
- `lib/nex/agent/extension/plugin/template.ex`
- `lib/nex/agent/runtime/config.ex`
- `lib/nex/agent/sandbox/permission_rule.ex`
- `lib/nex/agent/sandbox/approval.ex`
- `lib/nex/agent/observe/control_plane/log.ex`
- `test/nex/agent/plugin_runtime_primitives_test.exs`
- `test/nex/agent/tasks_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

### 1) Hindsight 不是特殊 core backend

本 phase 不新增 `Memory.Hindsight`、`HindsightWorker`、`HindsightBackend`、memory-only runtime branch。

Hindsight 未来只能作为普通 plugin 接入：

```text
plugin manifest
  -> Runtime.Snapshot.plugins
  -> hooks / ToolRegistry / task trigger / PermissionRule / ControlPlane
```

`builtin` 只表示打包来源，不表示特权、不表示绕过权限、不表示 core memory backend。

### 2) 删除优先，不做过渡兼容

本 phase 的目标态是统一 Task。凡是目标态不应存在的公开或内部入口，开工时必须直接删除或改名，靠编译错误和测试失败找完整调用点。

必须删除或改名的旧概念：

```text
Cron public API
ScheduledTasks public API
/api/workbench/scheduled-tasks
tasks.scheduled.* bridge methods
PluginJobRunner
enqueue_job
contributes.jobs
plugin.job.* observations
tasks/cron_jobs.json runtime truth source
```

允许做一次性数据迁移，因为 `tasks/cron_jobs.json` 是已存在的用户持久数据；但迁移完成后 runtime 不能继续双读双写 `cron_jobs.json` 和 `tasks/tasks.json`。

不允许为了中间状态可编译而添加：

```text
Cron wrapper forwarding to Tasks
ScheduledTasks wrapper forwarding to Tasks
tasks.scheduled.* alias methods
contributes.jobs alias projection
PluginJobRunner shim
dual read/write task stores
```

### 3) Public Task contract

对外唯一任务 API 固定为：

```elixir
Nex.Agent.Tasks.list/1
Nex.Agent.Tasks.get/2
Nex.Agent.Tasks.upsert/2
Nex.Agent.Tasks.delete/2
Nex.Agent.Tasks.enable/3
Nex.Agent.Tasks.run_now/3
Nex.Agent.Tasks.status/1
```

Workbench HTTP 路径固定为：

```text
/api/workbench/tasks
/api/workbench/tasks/:task_id
/api/workbench/tasks/:task_id/run
/api/workbench/tasks/:task_id/enable
/api/workbench/tasks/:task_id/disable
```

Workbench bridge methods 固定为：

```text
tasks.list
tasks.status
tasks.upsert
tasks.delete
tasks.enable
tasks.disable
tasks.run
```

Plugin contribution 固定为：

```json
{
  "contributes": {
    "tasks": []
  }
}
```

不再使用 `jobs` 作为 manifest contribution key。

Task definition 固定最小 shape：

```json
{
  "id": "memory.retain",
  "title": "Retain memory",
  "enabled": true,
  "triggers": [
    {"type": "event", "event": "conversation.turn.finished"}
  ],
  "policy": {
    "debounce_key": "memory.retain:{{session.key}}",
    "debounce_ms": 3000,
    "max_runs": 1
  },
  "action": {
    "type": "tool_call",
    "tool": "memory__retain",
    "args": {}
  }
}
```

每次执行叫 Run，是内部 observation/status 概念，不作为独立 public API。

### 4) Runtime task truth source

`Runtime.Snapshot` 必须新增 `tasks` projection，作为长期进程看到 task 的唯一真相源：

```elixir
%{
  definitions: [map()],
  diagnostics: [map()],
  hash: String.t(),
  path: String.t() | nil
}
```

来源只允许：

```text
workspace tasks/tasks.json
plugin contributes.tasks
system/internal tasks
```

不允许 `Cron`、Workbench、plugin runtime 各自读取任务文件。

### 5) MCP transport contract

新增或重构后的 MCP 主链固定为：

```text
ServerManager
  -> MCP.Client
       -> Transport.Stdio
       -> Transport.StreamableHTTP
  -> protocol methods
       initialize
       list_tools
       call_tool
       stop
```

上层只能调用统一 API：

```elixir
@callback initialize(pid(), timeout()) :: :ok | {:error, term()}
@callback list_tools(pid(), timeout()) :: {:ok, map() | list()} | {:error, term()}
@callback call_tool(pid(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
@callback stop(pid()) :: :ok
```

不允许 `ToolRegistry`、plugin runtime、hook/task executor 按 transport 分支调用。

### 6) Plugin MCP server manifest shape

stdio 形态继续支持：

```json
{
  "id": "local_memory",
  "transport": "stdio",
  "command": "memory-mcp",
  "args": ["--workspace", "{{workspace.root}}"],
  "env": {
    "TOKEN": "{{plugin.config.memory_api_token}}"
  }
}
```

Phase 23 不保留无 `transport` 的旧形态；现有测试和 fixture 必须一次性迁移为显式 `transport: "stdio"`。

streamable HTTP 形态固定为：

```json
{
  "id": "remote_memory",
  "transport": "streamable-http",
  "url": "{{plugin.config.endpoint}}/mcp",
  "headers": {
    "Authorization": "{{plugin.config.authorization_header}}",
    "X-Memory-Bank": "{{plugin.config.bank.template}}"
  },
  "timeout_ms": 30000
}
```

`headers` 使用 plugin config 渲染；值为空字符串时调用方应省略该 header。

### 7) Template syntax

本 phase 统一使用 `{{path.to.value}}`。

必须支持：

```text
{{plugin.id}}
{{plugin.config.<key>}}
{{workspace.root}}
{{workspace.hash}}
{{session.key}}
{{turn.prompt}}
{{channel}}
{{chat_id}}
```

bank template 必须通过同一模板机制表达，例如：

```json
{
  "bank": {
    "template": "nex-{{workspace.hash}}"
  }
}
```

模板解析结果保留统一 result shape，方便调用方在需要时继续携带展示值。

### 8) Plugin service credential config

plugin service credentials 直接作为 plugin config 字段进入统一 config contract，例如 `authorization_header`。本 phase 不新增独立 secret resolver。

第一版 resolver 可以只支持环境变量或 runtime config 声明，但必须满足：

- secret id 是稳定逻辑名，不是明文值。
- protected config 文件仍然不可被业务代码直接读取。
- secret 明文只允许进入执行边界：HTTP header、stdio env、tool request body 中明确需要的位置。
- ControlPlane/log/diagnostics/snapshot 中只能出现 secret id 或 `[REDACTED]`。

### 9) Task trigger contract

Phase 22 的 `jobs` 语义在本 phase 删除，改为 task definition。manifest key 必须叫 `tasks`：

```json
{
  "id": "memory.retain",
  "trigger": {
    "type": "event",
    "event": "conversation.turn.finished"
  },
  "policy": {
    "debounce_key": "memory.retain:{{session.key}}",
    "debounce_ms": 3000,
    "max_runs": 1
  },
  "action": {
    "type": "tool_call",
    "tool": "memory__retain",
    "args": {
      "bank": "{{plugin.config.bank.template}}",
      "text": "{{turn.transcript}}"
    }
  }
}
```

cron trigger 固定为同一 task shape：

```json
{
  "id": "memory.compact",
  "trigger": {
    "type": "schedule",
    "schedule": {"type": "cron", "expr": "0 3 * * *"}
  },
  "policy": {
    "debounce_key": "memory.compact:{{workspace.hash}}",
    "max_runs": 1
  },
  "action": {
    "type": "tool_call",
    "tool": "memory__compact",
    "args": {}
  }
}
```

本 phase 要求 event trigger、schedule trigger、manual trigger 都进入同一 Task scheduler / runner；schedule trigger 继承原 scheduled task 用户行为，但不再依赖 `Cron` 作为 public API 或 runtime truth source。

### 10) Queue policy semantics

`debounce_key`：相同 key 的 pending task 在 `debounce_ms` 窗口内合并为一次执行，使用最后一次 rendered ctx。

`debounce_ms`：缺省为 `0`，表示不防抖。

`max_runs`：一次触发批次最多执行次数。第一版只支持 `1`，不支持无限 retry。

不允许在本 phase 添加：

- arbitrary retry DSL
- operation polling DSL
- plugin-owned long-running worker
- arbitrary shell/script action

### 11) Permission and observation contract

所有 effectful action 继续走现有统一链路：

- stdio MCP process start -> `Sandbox.Exec` / `Approval` / `PermissionRule`
- streamable HTTP MCP connect/call -> `Approval` / `PermissionRule` 的 `:mcp` 或 network resource requirement
- hook tool call -> `ToolRegistry.execute/3`
- task tool call -> `ToolRegistry.execute/3`
- workspace file write -> `Sandbox.FileSystem`

ControlPlane 至少记录：

```text
plugin.mcp.transport.started
plugin.mcp.transport.failed
plugin.mcp.call.started
plugin.mcp.call.finished
plugin.task.queued
plugin.task.debounced
plugin.task.started
plugin.task.finished
plugin.task.failed
plugin.template.render.failed
```

## 执行顺序 / stage 依赖

1. Stage 1：Task public surface cutover，先删除 Cron/ScheduledTask/PluginJob 对外入口，建立 `Nex.Agent.Tasks` 与 `snapshot.tasks`。
2. Stage 2：MCP transport boundary，拆 protocol/transport，不复制 MCP 方法实现。
3. Stage 3：streamable HTTP MCP client，依赖 Stage 2。
4. Stage 4：plugin template + direct plugin config rendering，依赖 Stage 2/3，因为 HTTP headers/env 需要统一渲染。
5. Stage 5：Task runner trigger/policy，依赖 Stage 1/4。
6. Stage 6：fake external memory plugin end-to-end 验收，依赖 Stage 3/4/5。

## Stage 1

### 前置检查

- 确认当前 `Cron` / `ScheduledTasks` / `PluginJobRunner` 依赖点已搜索清楚。
- 确认 `tasks/cron_jobs.json` 是需要迁移的用户持久数据。
- 读取 `lib/nex/agent/capability/cron.ex`、`lib/nex/agent/interface/workbench/scheduled_tasks.ex`、`lib/nex/agent/runtime/plugin_job_runner.ex`。

### 这一步改哪里

- `lib/nex/agent/tasks.ex`（新增）
- `lib/nex/agent/tasks/store.ex`（新增）
- `lib/nex/agent/tasks/projector.ex`（新增）
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/runtime/runtime.ex`
- `lib/nex/agent/interface/workbench/tasks.ex`（新增）
- `lib/nex/agent/interface/workbench/scheduled_tasks.ex`（删除）
- `lib/nex/agent/capability/cron.ex`（删除或并入 `Nex.Agent.Tasks.Scheduler`）
- `lib/nex/agent/runtime/plugin_job_runner.ex`（删除）
- `lib/nex/agent/capability/hooks.ex`
- `test/nex/agent/tasks_surface_test.exs`（新增）
- `test/nex/agent/workbench/tasks_test.exs`（新增或替换 scheduled tasks 测试）
- `test/nex/agent/plugin_runtime_primitives_test.exs`

### 这一步要做

- 新增 `Nex.Agent.Tasks` public API。
- 新增 `Runtime.Snapshot.tasks` projection。
- 迁移 workspace `tasks/cron_jobs.json` 到 `tasks/tasks.json`，迁移后 runtime 只读 `tasks/tasks.json`。
- Workbench HTTP route 改为 `/api/workbench/tasks`。
- Bridge method 改为 `tasks.*`。
- Plugin contribution key 改为 `tasks`，删除 `jobs` projection。
- hook action 改为 `enqueue_task`，删除 `enqueue_job`。

### 实施注意事项

- 不要保留 `Cron` wrapper、`ScheduledTasks` wrapper、`PluginJobRunner` shim。
- 不要保留 `/api/workbench/scheduled-tasks` 或 `tasks.scheduled.*` alias。
- 不要双读双写 `cron_jobs.json`。
- 用编译错误和测试失败驱动所有调用点迁移。

### 本 stage 验收

- 对外只有 `Nex.Agent.Tasks`、`/api/workbench/tasks`、`tasks.*`、`contributes.tasks`。
- `Runtime.Snapshot.tasks` 是 task projection truth source。
- 旧 cron persisted data 被一次性迁移。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/tasks_surface_test.exs test/nex/agent/workbench/tasks_test.exs test/nex/agent/plugin_runtime_primitives_test.exs
/opt/homebrew/bin/mix compile --warnings-as-errors
```

## Stage 2

### 前置检查

- Stage 1 已通过。
- 确认现有 stdio MCP tests 或 plugin MCP tests 能复现当前行为。
- 读取 `lib/nex/agent/interface/mcp.ex` 和 `lib/nex/agent/interface/mcp/server_manager.ex`。

### 这一步改哪里

- `lib/nex/agent/interface/mcp.ex`
- `lib/nex/agent/interface/mcp/client.ex`（新增）
- `lib/nex/agent/interface/mcp/transport/stdio.ex`（新增）
- `lib/nex/agent/interface/mcp/server_manager.ex`
- `test/nex/agent/mcp_client_test.exs`（新增或更新）
- `test/nex/agent/plugin_runtime_primitives_test.exs`

### 这一步要做

- 把 MCP JSON-RPC method assembly / request id / pending response 语义从 stdio process 细节中抽出来。
- stdio transport 继续使用 `Sandbox.Process` 或现有等价安全入口。
- `ServerManager.start_server/3` 根据 normalized transport 创建 client，不直接假设 `command`。

### 实施注意事项

- 不要让 `ServerManager` 复制 `list_tools` / `call_tool` JSON-RPC 细节。
- 不要让 `ToolRegistry` 感知 stdio/HTTP。
- 不要改变 Phase 22 plugin MCP server id contract：`"plugin:" <> plugin_id <> ":" <> server_name`。

### 本 stage 验收

- 现有 stdio MCP plugin tool 可见性和执行行为不变。
- `MCP.Client` 有清晰 transport boundary。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/plugin_runtime_primitives_test.exs test/nex/agent/mcp_client_test.exs
/opt/homebrew/bin/mix compile --warnings-as-errors
```

## Stage 3

### 前置检查

- Stage 2 已通过。
- 已读官方 MCP transport spec：`https://modelcontextprotocol.io/specification/2025-11-25/basic/transports`。

### 这一步改哪里

- `lib/nex/agent/interface/mcp/transport/streamable_http.ex`（新增）
- `lib/nex/agent/interface/mcp/client.ex`
- `lib/nex/agent/interface/mcp/server_manager.ex`
- `lib/nex/agent/extension/plugin/manifest.ex`
- `lib/nex/agent/extension/plugin/contribution.ex`
- `test/nex/agent/mcp_streamable_http_test.exs`（新增）
- `test/nex/agent/plugin_runtime_primitives_test.exs`

### 这一步要做

- 支持 plugin `mcpServers` 的 `transport: "streamable-http"`。
- 实现 HTTP POST JSON-RPC request。
- 支持 JSON response 和 POST SSE response。
- 初始化后保存 session id header，并在后续请求带回。
- 对 GET SSE listener 只做最小可选支持；不作为 tool call 主路径依赖。

### 实施注意事项

- HTTP 请求优先走 `Nex.Agent.HTTP`；如果现有抽象不够，先补底层抽象，不要在功能代码裸用 `Req`。
- headers 中的 secret 必须先经过 redaction-aware template resolver；本 stage 可以先接 stub，Stage 4 完成最终安全 contract。
- network permission 不要通过 manifest 自动授权。

### 本 stage 验收

- fake streamable HTTP MCP server 能完成 initialize/list_tools/call_tool。
- server 返回 `Mcp-Session-Id` 后，后续 call 带该 header。
- GET SSE 返回 405 不影响 POST request/response 主路径。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/mcp_streamable_http_test.exs test/nex/agent/plugin_runtime_primitives_test.exs
/opt/homebrew/bin/mix compile --warnings-as-errors
```

## Stage 4

### 前置检查

- Stage 3 已通过。
- 确认 `~/.nex/agent/config.json` 和 `~/.zshrc` 仍是安全禁区，不允许直接读取。

### 这一步改哪里

- `lib/nex/agent/extension/plugin/template.ex`
- `lib/nex/agent/secret_base.ex`（新增）
- `lib/nex/agent/runtime/config.ex`
- `lib/nex/agent/interface/mcp/server_manager.ex`
- `lib/nex/agent/interface/mcp/transport/stdio.ex`
- `lib/nex/agent/interface/mcp/transport/streamable_http.ex`
- `test/nex/agent/plugin_template_test.exs`（新增）
- `test/nex/agent/mcp_streamable_http_test.exs`

### 这一步要做

- 扩展 `Template.render/2` 或新增 resolver，使其支持 `{{path.to.value}}`。
- 支持 plugin config、workspace、session、turn、channel、chat_id。
- resolver 返回 rendered value 和统一 result shape。
- MCP stdio env、streamable HTTP headers 统一使用 resolver。

### 实施注意事项

- 不要读取安全禁区文件。
- 不要支持 `${...}`。
- 空 header 渲染结果必须省略，避免使用空 token 静默连接。

### 本 stage 验收

- `{{plugin.config.endpoint}}`、`{{plugin.config.authorization_header}}`、`{{workspace.hash}}`、`{{session.key}}` 可渲染。
- 空 header 渲染结果不会发出对应 HTTP header。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/plugin_template_test.exs test/nex/agent/secret_base_test.exs test/nex/agent/mcp_streamable_http_test.exs
/opt/homebrew/bin/mix compile --warnings-as-errors
```

## Stage 5

### 前置检查

- Stage 4 已通过。
- 确认 Stage 1 已删除 `Cron` / `PluginJobRunner` public/internal queue 入口。

### 这一步改哪里

- `lib/nex/agent/tasks/runner.ex`（新增）
- `lib/nex/agent/tasks/scheduler.ex`（新增）
- `lib/nex/agent/capability/hooks.ex`
- `lib/nex/agent/extension/plugin/contribution.ex`
- `lib/nex/agent/runtime/runtime.ex`
- `test/nex/agent/plugin_task_runner_test.exs`（新增）
- `test/nex/agent/tasks_scheduler_test.exs`（新增）
- `test/nex/agent/plugin_runtime_primitives_test.exs`

### 这一步要做

- 实现统一 Task runner / scheduler。
- hook 的 `enqueue_task` enqueue task definition。
- 实现 `debounce_key` / `debounce_ms` / `max_runs: 1`。
- schedule trigger 使用 `Tasks.Scheduler`，不再依赖 `Cron`。
- task action 继续只支持 Phase 22 的 `tool_call`、`write_workspace_file`。
- 为现有 scheduled user task 支持 `agent_turn` action。

### 实施注意事项

- 不要实现 operation polling DSL。
- 不要实现 arbitrary retry。
- 不要允许插件声明 shell/script action。
- debounce 合并时使用最后一次 rendered ctx，避免旧 turn prompt 覆盖新 turn。

### 本 stage 验收

- 同一个 `debounce_key` 在窗口内多次 enqueue 只执行一次。
- `max_runs: 1` 阻止同一触发批次重复执行。
- schedule trigger 和原 scheduled user task 行为一致，但 public surface 是 Task。
- task started/finished/debounced/failed 都有 ControlPlane observation。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/plugin_task_runner_test.exs test/nex/agent/tasks_scheduler_test.exs test/nex/agent/plugin_runtime_primitives_test.exs
/opt/homebrew/bin/mix compile --warnings-as-errors
```

## Stage 6

### 前置检查

- Stage 3、4、5 已通过。
- 确认测试 plugin 不命名为 Hindsight，不引入 memory 专用 runtime branch。

### 这一步改哪里

- `test/nex/agent/plugin_external_service_foundation_test.exs`（新增）
- `test/support` 下可新增 fake streamable HTTP MCP server helper
- `docs/dev/task-plan/phase23-plugin-external-service-foundation.md`（只在验收命令变化时同步）

### 这一步要做

- 构造 fake external memory plugin：
  - `mcpServers` 使用 streamable HTTP。
  - `tools` 暴露 `fake_memory__recall`、`fake_memory__retain`。
  - `hooks` 在 `prompt.build.before` 调 recall tool。
  - task 在 `conversation.turn.finished` 调 retain tool，带 debounce policy。
  - `workspaceFiles` 声明 status/cache 文件。
- 验证 plugin disabled 后 tool 不可见且不可执行。
- 验证 secret 不出现在 snapshot/diagnostics/ControlPlane/log captured output。

### 实施注意事项

- fake server 只用于证明通用底座，不要把 Hindsight API shape 写成 core contract。
- 不要要求真实 Hindsight credentials。
- 不要访问用户真实 secret/config 文件。

### 本 stage 验收

- 一个端到端测试证明 external memory plugin 的最小闭环：recall 注入、retain debounce、HTTP MCP call、secret header、bank template。
- Hindsight 后续可以作为普通 plugin 复用该底座，无需改 Runner/ContextBuilder/ToolRegistry 特判。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/plugin_external_service_foundation_test.exs test/nex/agent/plugin_runtime_primitives_test.exs test/nex/agent/mcp_streamable_http_test.exs test/nex/agent/plugin_task_runner_test.exs
/opt/homebrew/bin/mix compile --warnings-as-errors
```

## Review Fail 条件

- Hindsight 或任意 memory service 被做成 core backend、特殊 worker、特殊 ContextBuilder 分支。
- `builtin` 插件获得权限特权或绕过 PermissionRule。
- `ToolRegistry`、Runner、hook executor 按 MCP transport 写分支。
- streamable HTTP 和 stdio 复制两套 MCP protocol method 实现。
- `${...}` 被引入为 plugin template 语法。
- 业务模块直接读取 `~/.nex/agent/config.json`、`~/.zshrc` 或其他安全禁区。
- plugin manifest 自动授予 network/file/MCP/tool 权限。
- 新增第二套 schedule 持久文件或和 `Runtime.Snapshot.tasks` 并行的 task truth source。
- 新增 operation polling DSL、arbitrary retry DSL、plugin-owned long-running worker。
- fake external memory plugin 测试只能跑 happy path，没有覆盖 disabled plugin、permission deny、空 header 省略、debounce 合并。
