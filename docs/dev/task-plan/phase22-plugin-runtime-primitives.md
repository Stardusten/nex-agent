# Phase 22 Plugin Runtime Primitives

## 当前状态

当前 plugin host 只把 `channels/providers/tools/skills/commands` 这五类 contribution 投影进 runtime。`hooks` 仍然主要是 workspace `hooks/hooks.json` 的能力，`jobs`、`workspaceFiles`、`mcpServers` 还没有作为 runtime 级声明进入统一主链。

当前代码的问题：

- plugin 还不能用统一声明方式接入 `prompt.build.before` 之外的生命周期自动化。
- plugin 的后台维护动作缺少 runtime-owned job runner，只能在局部路径里手写逻辑。
- plugin workspace 文件缺少统一初始化和 watch projection。
- plugin MCP server 缺少 runtime projection 和统一 lifecycle 管理。
- plugin tool 的 module/MCP source 支持不完整，定义、可见性、执行、权限和观测还没有完全收口到同一主链。
- phase22 的保守目标要求“不新增 manifest 自动授权、不新增 plugin 自己的权限真相源”，但实现时很容易滑向额外的平行 allow/deny 逻辑。

## 完成后必须达到的结果

1. plugin manifest 新增并支持这四类 contribution：
   - `hooks`
   - `jobs`
   - `workspaceFiles`
   - `mcpServers`
2. `Runtime.Snapshot.plugins.contributions` 必须包含：
   - `hooks`
   - `jobs`
   - `workspace_files`
   - `mcp_servers`
3. runtime 是这些 contribution 的唯一热重载与可见性真相源：
   - `ToolRegistry` 不再持有第二份 plugin-derived state
   - plugin MCP tool 的可见性来自 snapshot/plugin projection，而不是 live manager 私有判断
4. `prompt.build.before` 与 `conversation.turn.finished` 都走同一条 hook 主链。
5. `jobs` 只能通过 hook 的显式动作触发；`Runner` 不允许直接按 event 匹配 jobs。
6. 新增 runtime-owned plugin job runner，支持最小动作：
   - `tool_call`
   - `write_workspace_file`
7. `workspaceFiles.onMissing=create` 必须由 runtime 初始化，且这一写入路径要么明确作为 reviewed runtime-owned bootstrap，要么走统一文件授权链；本 phase 选择走统一文件授权链。
8. plugin-declared MCP server 由 runtime reconcile 管理启停，至少支持 stdio 形态。
9. plugin-declared tool source 支持：
   - `from: "module:Elixir.Module.Name"`
   - `from: "mcp:server_id/tool_name"`
10. 所有 plugin effectful action 继续复用当前 sandbox/approval/rule system：
    - 没有 manifest 自动授权
    - 没有 install-time auto allow
    - manifest 里的 permission-like metadata 不是授权真相源
11. 需要有一个最小 demo plugin，证明：
    - workspace file 初始化
    - prompt hook 注入
    - module-backed tool 调用
    - turn-finished hook -> enqueue job -> tool reuse
    - MCP-backed tool 可见性与 server lifecycle 对齐
12. focused tests 能覆盖主成功路径和关键拒绝/降级路径。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/designs/2026-05-07-plugin-runtime-extension-primitives.md`
- `docs/dev/designs/2026-05-07-hindsight-memory-plugin.md`
- `docs/dev/findings/2026-04-29-plugin-runtime-boundary.md`
- `docs/dev/task-plan/phase20-plugin-runtime-foundation.md`
- `docs/dev/task-plan/phase21-command-sandbox-and-approval.md`
- `lib/nex/agent/extension/plugin/manifest.ex`
- `lib/nex/agent/extension/plugin/store.ex`
- `lib/nex/agent/extension/plugin/catalog.ex`
- `lib/nex/agent/extension/plugin/contribution.ex`
- `lib/nex/agent/runtime/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/runtime/watcher.ex`
- `lib/nex/agent/runtime/reconciler.ex`
- `lib/nex/agent/capability/hooks.ex`
- `lib/nex/agent/capability/tool/registry.ex`
- `lib/nex/agent/interface/mcp.ex`
- `lib/nex/agent/interface/mcp/server_manager.ex`
- `lib/nex/agent/sandbox/security.ex`
- `lib/nex/agent/sandbox/filesystem.ex`
- `lib/nex/agent/sandbox/permission_rule.ex`
- `lib/nex/agent/sandbox/approval.ex`
- `lib/nex/agent/turn/runner.ex`

## 固定边界 / 已冻结的数据结构与 contract

### 1) Plugin contribution kinds

本 phase 支持的 `contributes` kinds 固定为：

```json
{
  "channels": [],
  "providers": [],
  "tools": [],
  "skills": [],
  "commands": [],
  "hooks": [],
  "jobs": [],
  "workspaceFiles": [],
  "mcpServers": []
}
```

新增四类的 runtime projection key 固定为：

```elixir
%{
  hooks: [map()],
  jobs: [map()],
  workspace_files: [map()],
  mcp_servers: [map()]
}
```

### 2) Tool source contract

plugin tool declaration 固定支持：

```json
{
  "name": "tool_name",
  "from": "module:Elixir.Module.Name"
}
```

或：

```json
{
  "name": "tool_name",
  "from": "mcp:server_id/tool_name"
}
```

兼容读取旧 builtin manifests 里的 `"module"` 字段，但 runtime 内部必须统一规范化到 `from` 语义。

### 3) Hook action contract

plugin hook action 固定支持：

```json
{ "type": "add_text", "content": "..." }
{ "type": "add_file", "path": "..." }
{ "type": "add_tool_result", "tool": "tool_name", "args": {} }
{ "type": "enqueue_job", "job": "job_id" }
```

`conversation.turn.finished` 不直接执行 job；只允许通过 `enqueue_job` 触发 job runner。

### 4) Job action contract

plugin job action 固定支持：

```json
{ "type": "tool_call", "tool": "tool_name", "args": {} }
{ "type": "write_workspace_file", "path": "...", "content": "..." }
```

不允许在本 phase 新增 plugin-owned long-running worker、cron-like schedule、或任意脚本执行。

### 5) MCP lifecycle contract

plugin MCP server runtime id 固定为：

```elixir
"plugin:" <> plugin_id <> ":" <> server_name
```

runtime 在 build snapshot 时必须先 reconcile plugin MCP servers，再生成 `snapshot.tools`。  
`snapshot.plugins.active_mcp_servers` 是 MCP-backed plugin tool 可见性的唯一运行时来源。

### 6) Permission contract

本 phase 冻结以下规则：

- manifest 不授予权限
- plugin manifest 里的 permission-like metadata 不是执行真相源
- plugin file IO 走 `Sandbox.FileSystem`
- plugin tool call 走 `ToolRegistry.execute/3`
- plugin MCP connect/call 生成 `PermissionRule` 的 `:mcp` resource requirement
- actor / metadata 至少带：

```elixir
%{
  "plugin_id" => String.t(),
  "hook_id" => String.t() | nil,
  "job_id" => String.t() | nil,
  "mcp_server" => String.t() | nil
}
```

### 7) Demo plugin acceptance contract

demo plugin 固定 shape：

- 一个 `workspaceFile`
- 一个 module-backed tool
- 一个 `prompt.build.before` hook 用 `add_file`
- 一个 `conversation.turn.finished` hook 用 `enqueue_job`
- 一个 job 用 `tool_call`
- 一个 stdio `mcpServer`
- 一个 MCP-backed tool

最小验收行为：

- runtime load 后创建声明文件
- prompt 注入文件内容
- module-backed tool 可写状态
- after-turn hook 能 enqueue job，job 重用同一个 tool
- MCP-backed tool 只有在 server active 时才可见

## 执行顺序 / stage 依赖

- Stage 0：冻结数据结构与保守权限边界
- Stage 1：扩 contribution normalization 和 snapshot shape
- Stage 2：补 workspaceFiles init + watch projection
- Stage 3：把 tool source 统一到 module/MCP 两类
- Stage 4：把 MCP lifecycle 拉进 runtime build/reconcile 主链
- Stage 5：扩 hooks 到 plugin hooks + `conversation.turn.finished`
- Stage 6：新增 runtime-owned plugin job runner，并改成 hook -> enqueue job
- Stage 7：补 demo plugin 与 focused tests

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1。  
Stage 4 依赖 Stage 3。  
Stage 5 依赖 Stage 1。  
Stage 6 依赖 Stage 5。  
Stage 7 依赖 Stage 2/3/4/5/6。

## Stage 0

### 前置检查

- 确认 legacy memory runtime 已删掉，不再有 `memory` tool/plugin 主线。
- 确认当前 phase 采用 conservative path：
  - no manifest auto allow
  - no install-time auto approval

### 这一步改哪里

- `docs/dev/task-plan/phase22-plugin-runtime-primitives.md`

### 这一步要做

- 冻结本文件里的数据结构与行为 contract。

### 实施注意事项

- 不提前实现 Hindsight。
- 不在这一步补具体 plugin 业务逻辑。

### 本 stage 验收

- reviewer 能仅靠本文件理解本 phase 的实现边界。

### 本 stage 验证

- 人工检查 task-plan 结构完整。

## Stage 1

### 前置检查

- `Extension.Plugin.Contribution` 目前只支持 5 类 contribution。

### 这一步改哪里

- `lib/nex/agent/extension/plugin/contribution.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/runtime/runtime.ex`

### 这一步要做

- 扩 contribution normalization，支持 `hooks/jobs/workspaceFiles/mcpServers`。
- 扩 snapshot.plugins.contributions shape。
- 保持旧 kinds 不变。

### 实施注意事项

- 不新增平行 projection key 命名。
- normalization 失败只能产 diagnostics，不能把 runtime 打崩。

### 本 stage 验收

- enabled plugin 的新 kinds 能稳定出现在 snapshot.plugins.contributions。

### 本 stage 验证

- `mix test test/nex/agent/plugin/catalog_test.exs test/nex/agent/runtime_test.exs`

## Stage 2

### 前置检查

- snapshot 已经能拿到 `workspace_files` contribution。

### 这一步改哪里

- `lib/nex/agent/runtime/plugin_workspace_files.ex`
- `lib/nex/agent/runtime/runtime.ex`
- `lib/nex/agent/runtime/watcher.ex`

### 这一步要做

- runtime load 时初始化声明的 workspaceFiles。
- watch path 改成从 runtime projection 导出。

### 实施注意事项

- 本 phase 选择让 workspaceFiles 初始化走统一文件授权链，而不是裸 `File.*`。
- watcher 不得在 poll 路径里反查 `Runtime.current()` 造成自锁。

### 本 stage 验收

- plugin 声明的 watched workspace file 会被创建，并进入 watcher path。

### 本 stage 验证

- `mix test test/nex/agent/runtime_test.exs`

## Stage 3

### 前置检查

- tool contribution 已能读到 `from` 字段。

### 这一步改哪里

- `lib/nex/agent/capability/tool/registry.ex`
- `lib/nex/agent/capability/tool/core/tool_list.ex`
- `lib/nex/agent/observe/admin.ex`

### 这一步要做

- ToolRegistry 支持 `module:` / `mcp:` 两类 source。
- `plugin_module` 必须要求 module 有 `execute/2` 和 `definition/*` 才能进入 projection。
- `ToolList` / `Admin` 改成读 projected definitions，而不是 registry 库存。

### 实施注意事项

- `ToolRegistry` 不得持有 plugin-derived tool 的第二份长期 state。
- module-backed plugin tool 的最终可见名字以 manifest contribution name 为准。

### 本 stage 验收

- malformed plugin module 不崩 registry，只变成不可见/diagnostic。

### 本 stage 验证

- `mix test test/nex/agent/tool_registry_test.exs test/nex/agent/tool_alignment_test.exs`

## Stage 4

### 前置检查

- tool registry 已支持 MCP-backed plugin tool source。

### 这一步改哪里

- `lib/nex/agent/interface/mcp/server_manager.ex`
- `lib/nex/agent/runtime/runtime.ex`
- `lib/nex/agent/runtime/reconciler.ex`

### 这一步要做

- runtime build snapshot 时先 reconcile plugin MCP servers，再生成 tools definitions。
- `snapshot.plugins.active_mcp_servers` 成为 MCP-backed tool 可见性的唯一运行时来源。
- reconcile 不仅处理 add/remove，还要在 server declaration 变更时重建。

### 实施注意事项

- 不能在 runtime build 或 watcher poll 里反查 `Runtime.current()` 造成死锁。
- 不允许继续用 `ServerManager.list()` 作为 tool visibility 真相源。

### 本 stage 验收

- snapshot.tools 和 live visible MCP-backed tool 不再漂移。

### 本 stage 验证

- `mix test test/nex/agent/plugin_runtime_primitives_test.exs test/nex/agent/runtime_test.exs`

## Stage 5

### 前置检查

- hooks 目前只有 `prompt.build.before` 主链。

### 这一步改哪里

- `lib/nex/agent/capability/hooks.ex`
- `lib/nex/agent/turn/runner.ex`

### 这一步要做

- 支持 plugin hooks merge。
- 支持 `conversation.turn.finished` hook event。
- 新增 `enqueue_job` action。

### 实施注意事项

- `conversation.turn.finished` 不能只是“定义上支持”，必须在 Runner 里真实执行。
- hook file read 统一走 `Sandbox.FileSystem`。

### 本 stage 验收

- prompt hook 和 after-turn hook 都走同一 `Hooks.run/3` 主链。

### 本 stage 验证

- `mix test test/nex/agent/hooks_test.exs test/nex/agent/plugin_runtime_primitives_test.exs`

## Stage 6

### 前置检查

- `enqueue_job` action 已可从 hook 触发。

### 这一步改哪里

- `lib/nex/agent/runtime/plugin_job_runner.ex`
- `lib/nex/agent/turn/runner.ex`

### 这一步要做

- `PluginJobRunner` 改成只接收 hook 指定的 job id，不再自己按 event 扫描 jobs。
- Runner 删除 direct job matcher 逻辑。

### 实施注意事项

- 不引入第二套 lifecycle 自动化系统。
- 不允许 jobs 自己再做 event-level orchestration。

### 本 stage 验收

- after-turn 自动化路径固定为 `hook -> enqueue_job -> job runner`。

### 本 stage 验证

- `mix test test/nex/agent/plugin_runtime_primitives_test.exs`

## Stage 7

### 前置检查

- 前 6 stages 的主链已经通。

### 这一步改哪里

- `test/nex/agent/plugin_runtime_primitives_test.exs`
- `test/nex/agent/plugin/catalog_test.exs`
- `test/nex/agent/runtime_test.exs`

### 这一步要做

- 用 demo plugin 覆盖：
  - workspace file 初始化
  - prompt hook
  - module-backed tool
  - after-turn hook -> job
  - MCP-backed tool visibility与server lifecycle
  - malformed plugin module 降级而不崩

### 实施注意事项

- focused tests 必须验证 conservative permission behavior，而不是跳过它。
- 如果测试需要手工启动 demo MCP server，只能用于单独执行路径验证；snapshot visibility 验证必须跟 runtime reconcile 语义一致。

### 本 stage 验收

- reviewer 点名的核心路径有 focused regression coverage。

### 本 stage 验证

- `mix compile --warnings-as-errors`
- `mix test test/nex/agent/plugin_runtime_primitives_test.exs`
- `mix test test/nex/agent/plugin/catalog_test.exs test/nex/agent/runtime_test.exs`

## Review Fail 条件

- plugin-derived tools 仍然依赖 `ToolRegistry` 的第二真相源。
- MCP-backed tool visibility 仍然依赖 `ServerManager.list()` live 状态而不是 snapshot projection。
- malformed `plugin_module` 仍然会把 registry 弄崩。
- `conversation.turn.finished` 仍然通过 Runner/job matcher 直接触发，而不是 hook -> enqueue job。
- plugin MCP connect/call 仍然绕开统一 permission requirement shape。
- watcher 或 runtime build 里再次出现 `Runtime.current()` 自锁路径。
- `workspaceFiles` 初始化/写入继续绕过统一文件授权链。
