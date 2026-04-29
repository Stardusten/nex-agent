# 2026-04-28 Workbench App Authoring Guide

本文档面向后续接手 Workbench app 开发的新 agent。目标是让新 agent 能清楚区分：

- 当前 Workbench runtime 已经实现了什么。
- 写 app 时可以依赖哪些 contract。
- 哪些能力还没实现，不能提前假设。
- notes / stock-dashboard 这类 app 应该落在哪一层、走哪条权限和数据链路。

开工前先读：

- `docs/dev/progress/CURRENT.md`
- `docs/dev/designs/2026-04-28-workbench-app-runtime.md`
- `docs/dev/task-plan/phase18-workbench-app-runtime.md`

## 产品心智

Workbench 不是固定 Admin dashboard。它是一个 local-first app host，让 NexAgent 可以在长期使用中逐步长出新的本地 web 工具。

目标链路是：

```text
127.0.0.1:50051 / SSH tunnel
  -> Workbench.Server
  -> Workbench shell
  -> sandboxed iframe app
  -> host-mediated SDK bridge
  -> Nex Runtime / Tools / ControlPlane / Workspace
```

app 是 workspace artifact，不是 NexAgent 框架 CODE 层。notes、stock dashboard、timeline、project board 这类 app 应放在：

```text
<workspace>/workbench/apps/<id>/
```

Sessions、Scheduled Tasks、Configuration 这类管理 agent runtime 自身的页面属于 Workbench system view，应放在 `priv/workbench/shell.html` 和 `lib/nex/agent/workbench/**`，不要做成 workspace app。

只有 Workbench core/server/shell/SDK 自身的改动才属于 repo 内的 CODE 层，例如：

```text
lib/nex/agent/workbench/**
priv/workbench/**
test/nex/agent/workbench/**
```

## 当前实现状态

已经实现：

- `Nex.Agent.Interface.Workbench.AppManifest`
- `Nex.Agent.Interface.Workbench.Store`
- `Nex.Agent.Interface.Workbench.Permissions`
- `Nex.Agent.Interface.Workbench.Server`
- `Nex.Agent.Interface.Workbench.Router`
- `Nex.Agent.Interface.Workbench.Shell`
- `Nex.Agent.Interface.Workbench.SessionApp`
- 静态 prototype shell：`priv/workbench/shell.html`
- Runtime snapshot 中的 `snapshot.workbench`
- Admin overview 的 Workbench summary
- loopback HTTP JSON API
- app manifest store
- static iframe app entry serving through `/app-frame/:id`
- app-local static asset serving through `/app-assets/:id/<relative_path>`
- permission grant / revoke / check store
- permission granted / denied 的 ControlPlane observations
- host-mediated iframe SDK bridge for `permissions.current`, `observe.summary`, and `observe.query`

尚未实现：

- file / notes SDK endpoints
- tool-call SDK endpoints
- controlled app reload/build runner for app-local `reload.sh`
- agent-facing app create/update tool
- notes app
- stock-dashboard app

重要约束：

- app 只能通过 `window.Nex.call(...)` / `window.Nex.*` 调用已开放的 bridge method。
- 不要为了某个 app 把业务逻辑塞进 `Workbench.Server` / `Workbench.Router`。
- Workbench runtime 只要求静态 entry/assets；React/Vite/CodeMirror 之类是 app-local source/build 选择，不是 core runtime 要求。
- 复杂 app 可以带 `reload.sh`，但当前后端还没有受控执行它的 runner；实现前不要让 iframe 直接触发脚本。

## Runtime Config

Workbench server 的启用和端口来自 runtime config，并通过 `Runtime.Snapshot` 投影给长期进程。`Workbench.Server` 不直接读取 config 文件。

当前 config shape：

```json
{
  "gateway": {
    "workbench": {
      "enabled": true,
      "host": "127.0.0.1",
      "port": 50051
    }
  }
}
```

规则：

- `host` 会被规范化为 `127.0.0.1`。
- 当前 phase 不支持 public bind。
- 默认 `enabled=false`。
- `Workbench.Server` 必须消费 `snapshot.workbench.runtime`。
- 代码和测试都不能读取或写入 `~/.nex/agent/config.json`。
- 测试必须使用临时 `config_path` 和临时 workspace。

`Nex.Agent.Interface.HTTP` 是出站 HTTP client/proxy/observe 抽象，不是入站 server。Workbench server 接收浏览器请求，因此不复用 `Nex.Agent.Interface.HTTP`。但 app 或 bridge 如果要访问外部 API，例如股票行情，必须走 `Nex.Agent.Interface.HTTP` 或已有 tool/data source，不能裸用 `Req`。

## Manifest Contract

每个 app 必须有一个 manifest：

```text
<workspace>/workbench/apps/<id>/nex.app.json
```

最小 shape：

```json
{
  "id": "stock-dashboard",
  "title": "Stocks",
  "version": "0.1.0",
  "entry": "index.html",
  "permissions": [
    "observe:read"
  ],
  "chrome": {
    "topbar": "auto"
  },
  "metadata": {}
}
```

校验规则：

- `id` 必须匹配 `^[a-z][a-z0-9_-]{1,63}$`。
- `id` 是路径段，不允许 `/`、`.`、空白、大小写漂移或 URL 编码语义。
- `title` 必填，最长 120 字符，不能包含 control characters。
- `version` 默认 `0.1.0`，最长 64 字符，不能包含 control characters。
- `entry` 默认 `index.html`，必须是 relative path，且不能包含 `..` path segment。
- `permissions` 是字符串列表，每项非空、最长 160 字符、不能包含 control characters。
- duplicate permissions 会被 normalize 掉。
- `chrome` 是可选 object；`chrome.topbar` 可为 `auto` 或 `hidden`，默认 `auto`。
- `metadata` 必须是 object。
- 旧 manifest 中的 `runtime` 字段会被忽略；新 app 不要写 `runtime.kind` / `runtime.sandbox`。

在框架代码或测试里操作 app manifest 时，优先使用：

- `Nex.Agent.Interface.Workbench.Store.save/2`
- `Nex.Agent.Interface.Workbench.Store.get/2`
- `Nex.Agent.Interface.Workbench.Store.list/1`
- `Nex.Agent.Interface.Workbench.Store.load_all/1`

`load_all/1` 对 invalid app 返回 bounded diagnostics，不让一个坏 manifest 阻塞整个 Runtime reload。

## App Artifact And Reload Contract

Workbench app 采用类似 Obsidian plugin 的 artifact 心智：宿主只认少量标准运行产物，源码组织和构建方式由 app 自己决定。Obsidian plugin 发布时核心资产是 `manifest.json`、`main.js`、可选 `styles.css`；Workbench app 对应的是 `nex.app.json`、manifest `entry` 指向的 HTML、以及 app-local JS/CSS/assets。

标准 app 目录：

```text
<workspace>/workbench/apps/<id>/
  nex.app.json      # required manifest
  index.html        # standard static entry, optional if entry points elsewhere
  app.js            # standard static JS for simple apps
  style.css         # standard static CSS for simple apps
  assets/**         # static assets served by /app-assets/:id/*
  reload.sh         # optional app-local build/prepare script
  src/**            # optional source
  package.json      # optional app-local frontend metadata
  dist/**           # optional generated artifacts
```

Simple apps can directly edit top-level `index.html` / `app.js` / `style.css` and then reload the iframe.

Complex apps can keep source under `src/**`, run `reload.sh`, and point `entry` at a generated HTML artifact:

```json
{
  "id": "notes",
  "title": "Notes",
  "entry": "dist/index.html",
  "permissions": ["permissions:read", "notes:read", "notes:write"],
  "chrome": {"topbar": "hidden"}
}
```

`reload.sh` means:

```text
prepare this app directory so the manifest entry points at current runnable static artifacts
```

It does not mean core CODE deploy, browser iframe reload, arbitrary shell access, or permission approval.

Future controlled runner requirements:

- resolve the app through `Workbench.Store`
- run only that app's `reload.sh`
- set cwd to the app directory
- enforce timeout and output limits
- write ControlPlane observations for started / finished / failed
- return bounded stdout/stderr to the agent
- stay unavailable to iframe apps through `window.Nex`

App edit and activation lanes:

```text
simple app:
find/read -> apply_patch -> iframe Reload

buildable app:
find/read -> apply_patch -> controlled reload.sh runner -> iframe Reload

Workbench core CODE:
find/read/reflect -> apply_patch -> self_update deploy
```

Do not add a generic file-writing tool for app source. `reload.sh` is an artifact materialization hook, not a replacement for `apply_patch`.

## Permission Model

manifest 中的 `permissions` 只是 app 申请范围，不等于 owner 授权。

owner grant 真相源是：

```text
<workspace>/workbench/permissions.json
```

当前 API：

- `Permissions.grant(app_id, permission, opts)`
- `Permissions.revoke(app_id, permission, opts)`
- `Permissions.check(app_id, permission, opts)`
- `Permissions.app(app_id, opts)`
- `Permissions.list(opts)`

规则：

- 默认 deny。
- grant 只能授权 manifest 已声明的 permission。
- check 必须同时满足「manifest 已声明」和「owner 已授权」。
- manifest 后续删除某 permission 时，旧 grant 进入 `stale_granted_permissions`，不再是有效授权。
- denied checks 写 `workbench.permission.denied`。
- successful grants 写 `workbench.permission.granted`。

app 代码不能直接编辑 `permissions.json`。owner approval flow 和 host UI/action 才能管理 grant。

建议 permission 前缀：

```text
notes:read
notes:write
files:read:/notes
files:write:/notes
tools:call:stock_quote
observe:read
sessions:chat
tasks:read
tasks:write
```

permission 必须保持 capability-shaped。不要加 `tools:call:any`、`files:write:/` 这种过宽权限。

## 当前 HTTP API

当前 loopback API 很薄：

```text
GET  /workbench
GET  /
GET  /app-frame/:id
GET  /app-assets/:id/<relative_path>
GET  /api/workbench/apps
GET  /api/workbench/apps/:id
GET  /api/workbench/permissions/:id
POST /api/workbench/permissions/:id/grant
POST /api/workbench/permissions/:id/revoke
POST /api/workbench/bridge/:app_id/call
GET  /api/observe/summary
GET  /api/observe/query
GET  /api/workbench/evolution
GET  /api/workbench/evolution/candidates/:candidate_id
POST /api/workbench/evolution/candidates/:candidate_id/:action
GET  /api/workbench/sessions
GET  /api/workbench/sessions/:session_key
POST /api/workbench/sessions/:session_key/stop
POST /api/workbench/sessions/:session_key/model
GET  /api/workbench/config
PUT  /api/workbench/config/providers/:provider_key
DELETE /api/workbench/config/providers/:provider_key
PUT  /api/workbench/config/models/:model_key
DELETE /api/workbench/config/models/:model_key
PATCH /api/workbench/config/model-roles
PUT  /api/workbench/config/channels/:channel_id
DELETE /api/workbench/config/channels/:channel_id
```

`GET /api/workbench/sessions` 由 `Nex.Agent.Interface.Workbench.SessionApp` 投影，不维护平行 session state：

- session 是 NexAgent 的对话工作单元，key 形如 `channel:chat_id`，只有收到用户消息、运行命令、保存模型 override 或存在 active owner run 时才出现。
- channel 连接状态、Discord guild/thread cache、Feishu WebSocket 在线状态不等于 session，应放在 channel/connectivity surface 或 observability 中展示。
- 持久历史来自 workspace `sessions/*/messages.jsonl` / `SessionManager`。
- active 状态来自 `RunControl` owner run。
- stop 优先复用 `InboundWorker.stop_session/4`，确保真实 gateway 下会取消 owner task、follow-up、subagent 并清队列；没有 InboundWorker 时退到 `RunControl.cancel_owner/3`。
- model 切换写入 `Session` metadata 的 existing model override，并让 InboundWorker 丢弃 idle agent cache；已在运行的 task 仍使用启动时模型。

`POST /api/workbench/sessions/:session_key/model` body：

```json
{
  "model": "gpt-5.4"
}
```

`model` 也可以是数字序号或 `reset`，语义与聊天里的 `/model` 命令对齐。

`POST /grant` 和 `POST /revoke` body：

```json
{
  "permission": "notes:read"
}
```

`POST /api/workbench/evolution/candidates/:candidate_id/:action` 当前支持：

```text
action = approve | discard | apply
```

body 必须显式带二次确认：

```json
{
  "confirm": true,
  "decision_reason": "owner reason"
}
```

规则：

- `approve` 走 `evolution_candidate approve mode=plan`。
- `apply` 走 `evolution_candidate approve mode=apply`。
- `discard` 映射到 `evolution_candidate reject`。
- 未带 `confirm: true` 必须拒绝，且写 `workbench.bridge.call.failed`。
- 成功操作写 `workbench.bridge.call.started/finished`，并复用 `evolution.candidate.*` lifecycle observations。

当前 `/app-frame/:id` 读取 app manifest 的 `entry` 文件并注入 `window.Nex` SDK bootstrap。`/app-assets/:id/<relative_path>` 只服务该 app 目录下的静态资源，不服务 `nex.app.json`，不允许 `..` / absolute path / directory / app dir escape，第一版文件大小上限是 2MB。

当前配置面板是 Workbench shell 的内置 system view，不是 iframe app，也不是通用 JSON 编辑器。它通过 `Nex.Agent.Interface.Workbench.ConfigPanel` 操作 runtime config 的 provider/model/channel section：

- provider 支持新增、修改、删除；删除仍被 model 引用的 provider 会拒绝。
- model 支持新增、修改、删除；删除仍被 model role 引用的 model 会拒绝。
- model role 通过独立结构化表单修改 `default_model`、`cheap_model`、`memory_model`、`advisor_model`。
- channel 支持 Feishu / Discord 实例的新增、修改、删除。
- secret 字段只返回 `env` / `configured` / `none` 状态，不回显 token、api key、app secret 明文。
- 配置变更会先校验 next runtime config；enabled channel 必须带齐必填 secret。
- 成功写入后触发 `Runtime.reload/1`，并在响应中返回 `runtime_reload` 状态。
- reload 失败时必须回滚到旧 raw config，返回错误，并写 `workbench.config.update_failed`。

`GET /api/observe/query` 只接受固定观察筛选参数，不接受文件路径：

```text
tag
tag_prefix
kind
level
run_id
session_key
channel
chat_id
tool
tool_call_id
tool_name
trace_id
query
since
limit
```

返回 shape：

```json
{
  "filters": {},
  "observations": []
}
```

`tool` 是便利用 filter，可匹配 `attrs.tool_name` 或 `context.tool_call_id`。Workbench shell 的 timeline/detail 面板必须继续通过 `ControlPlane.Query` 派生数据，不直接读 `control_plane/observations/*.jsonl`。

server 当前约束：

- 只绑定 loopback。
- request headers/body 有上限。
- error response bounded。
- response 使用 `Connection: close`。
- prototype shell 是 no-build HTML。

## SDK Bridge

browser boundary 是：

```text
iframe app
  -> window.postMessage()
  -> Workbench host shell
  -> Workbench API
  -> backend permission check
  -> Nex Runtime / Tool / ControlPlane
```

iframe 不能持有 backend token，也不能直接调用任意 backend route。

iframe request shape：

```json
{
  "nex": "workbench.bridge.request",
  "version": 1,
  "call_id": "call_123",
  "method": "observe.query",
  "params": {}
}
```

response 带回同一个 `call_id`：

```json
{
  "nex": "workbench.bridge.response",
  "version": 1,
  "call_id": "call_123",
  "ok": true,
  "result": {}
}
```

host shell 只接受当前 iframe `contentWindow` 发来的 request，并从当前选中的 iframe 绑定 app id。iframe 传入的 `app_id` 会被忽略。

当前 backend bridge method allowlist：

```text
permissions.current -> permissions:read
observe.summary     -> observe:read
observe.query       -> observe:read
notes.roots.list    -> notes:read
notes.files.list    -> notes:read
notes.file.read     -> notes:read
notes.file.write    -> notes:write
notes.file.delete   -> notes:write
notes.search        -> notes:read
tasks.scheduled.list    -> tasks:read
tasks.scheduled.status  -> tasks:read
tasks.scheduled.add     -> tasks:write
tasks.scheduled.update  -> tasks:write
tasks.scheduled.remove  -> tasks:write
tasks.scheduled.enable  -> tasks:write
tasks.scheduled.disable -> tasks:write
tasks.scheduled.run     -> tasks:write
```

Scheduled Tasks 的内置管理界面走 Workbench system HTTP API；上面的 bridge methods 只给未来自定义 app 在 owner grant 后复用同一条 bounded control chain。

每次 bridge call 都要写 ControlPlane observations：

```text
workbench.bridge.call.started
workbench.bridge.call.finished
workbench.bridge.call.failed
workbench.bridge.call.denied
```

不要暴露 generic arbitrary tool call。应先定义 bounded bridge method，再把每个 method 映射到明确 capability。

## App Authoring Rules

创建或维护 app 时：

1. 先选稳定 app id。
2. 创建或更新 `nex.app.json`。
3. 只声明 app 真正需要的 permissions。
4. app 业务状态放在 app 目录或明确的 workspace data source。
5. shell layout 状态未来放 `workbench/layout.json`，不要混进 app 业务状态。
6. 不要把 owner grant 写进 manifest。
7. 不要把 app-specific business logic 写进 Workbench core。
8. app 不能读取任意 absolute path。
9. iframe 不要直接抓公网数据；需要外部数据时走 tool/data source/`Nex.Agent.Interface.HTTP`。
10. 先补 manifest、permission、bridge enforcement 测试，再依赖 UI 行为。
11. 创建和修改 app 文件走现有文件主链：`find -> read -> apply_patch`。
12. simple app 的静态产物改动后，在 Workbench 里点当前 app 的 iframe `Reload` 生效。
13. buildable app 如果存在 `reload.sh`，后续应先走受控 app reload/build runner，再刷新 iframe；当前 runner 未实现时不要假设脚本会自动执行。
14. 只有 Workbench core CODE 改动才需要 `self_update deploy`。

app source 不是 CODE 层。把 app 当成 workspace artifact。只有改 `lib/nex/agent/**` 这类框架内部实现时，才进入 CODE self-update 主链和 repo 测试/review 路径。

最小静态 app：

```text
<workspace>/workbench/apps/hello/nex.app.json
<workspace>/workbench/apps/hello/index.html
<workspace>/workbench/apps/hello/app.js
<workspace>/workbench/apps/hello/style.css
```

```json
{
  "id": "hello",
  "title": "Hello",
  "entry": "index.html",
  "permissions": ["permissions:read"]
}
```

```html
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <main id="app"></main>
  <script src="app.js"></script>
</body>
</html>
```

```javascript
async function main() {
  const permissions = await window.Nex.permissions();
  document.getElementById("app").textContent = JSON.stringify(permissions, null, 2);
}

main().catch((error) => {
  document.getElementById("app").textContent = error.message;
});
```

buildable app 示例：

```text
<workspace>/workbench/apps/notes/nex.app.json
<workspace>/workbench/apps/notes/reload.sh
<workspace>/workbench/apps/notes/package.json
<workspace>/workbench/apps/notes/src/main.tsx
<workspace>/workbench/apps/notes/dist/index.html
<workspace>/workbench/apps/notes/dist/assets/**
```

```json
{
  "id": "notes",
  "title": "Notes",
  "entry": "dist/index.html",
  "permissions": ["notes:read", "notes:write"],
  "chrome": {"topbar": "hidden"}
}
```

```bash
#!/usr/bin/env bash
set -euo pipefail
npm run build
```

`reload.sh` 只是 app-local 约定。直到后端 controlled runner 落地前，文档里的 `reload.sh` 不代表 Workbench shell 或 iframe 已经能执行它。

## Notes App Guidance

notes app 的目标是 local Obsidian-like tool，但第一版 MVP 要窄：

- markdown file list
- ProseMark / CodeMirror 6 live markdown editor
- 通过 SDK bridge save/load
- search 是 read-only bridge method
- backlink/unlinked mentions 等知识关系放后续阶段

推荐前端：

- Vite + React + TypeScript
- CodeMirror 6 + ProseMark
- 小型本地 state store
- 不要手写 markdown parser，除非确实需要
- 用 app-local `reload.sh` 把 source materialize 成 manifest `entry` 指向的静态产物

backend / bridge 要求：

- notes root 配置在 `gateway.workbench.apps.notes.root`：

```json
{
  "gateway": {
    "workbench": {
      "apps": {
        "notes": {
          "root": "/Users/krisxin/Notes"
        }
      }
    }
  }
}
```

- `notes:read` 用于 list/load notes。
- `notes:write` 用于 save/delete notes。
- note vault 是外部 data root，不是第二个 NexAgent workspace。
- iframe 只传 `root_id` 和 vault-relative path，不传 absolute path。
- 后端把 `root_id` 解析成配置里的 notes root，并复用 `Nex.Agent.Sandbox.Security.validate_path/2` / `validate_write_path/2` 和 explicit notes root 边界。
- 第一版 bridge method 是 `notes.roots.list`、`notes.files.list`、`notes.file.read`、`notes.file.write`、`notes.file.delete`、`notes.search`。
- 写入和删除必须支持可选 `base_revision` 并做 conflict detection；有冲突时拒绝覆盖或删除。

不要让 iframe 把任意 absolute path 传给后端。

## Stock Dashboard Guidance

stock dashboard 是 Workbench app，不是 core Workbench 逻辑。

第一版 MVP：

- watchlist display
- quote table
- manual refresh
- basic status/error display

Stage 5B 后推荐前端：

- TanStack Table，适合 dense table。
- Observable Plot 或 ECharts，适合 chart panel。

backend / tool 要求：

- 使用 `tools:call:stock_quote` 或更窄的 stock quote capability。
- 行情查询应实现为 deterministic tool/data source。
- 外部 HTTP 调用必须使用 `Nex.Agent.Interface.HTTP`。
- watchlist 如果是用户长期偏好，沉淀到 USER/MEMORY；如果只是 app 布局状态，放 app config。

不要把股票 provider 细节写进 `Workbench.Server` 或 `Workbench.Router`。

## Testing Checklist

本机环境优先使用 `/opt/homebrew/bin/mix`。

Workbench core tests：

```bash
/opt/homebrew/bin/mix test test/nex/agent/workbench/store_test.exs test/nex/agent/workbench/permissions_test.exs test/nex/agent/workbench/assets_test.exs test/nex/agent/workbench/bridge_test.exs test/nex/agent/workbench/server_test.exs
```

Runtime/Admin projection tests：

```bash
/opt/homebrew/bin/mix test test/nex/agent/config_test.exs test/nex/agent/runtime_test.exs test/nex/agent/admin_test.exs
```

bridge work 落地时必须补测试：

- unauthorized bridge call 被拒绝并写 observation。
- authorized bridge call 成功并写 observation。
- host shell 只接受当前 iframe `contentWindow` 的 message。
- malformed request body 返回 bounded error。
- app manifest 变化会更新 runtime workbench hash。

## Handoff Checklist

新 app agent 开工前：

- 确认当前 bridge allowlist 是否满足 app 需求，不满足时先设计 bounded method 和 permission。
- 读 `lib/nex/agent/workbench/*`。
- 读 `test/nex/agent/workbench/*`。
- 确认 active workspace path，但不要读取安全禁区 config 文件。
- 判断任务是 app artifact work，还是 core Workbench CODE work。

编码时：

- app-specific code 放 `workspace/workbench/apps/<id>/`。
- core bridge/server 改动放 `lib/nex/agent/workbench/**`。
- host shell prototype 放 `priv/workbench/shell.html`。
- 不重新引入 `runtime.kind` / Vite / HMR 作为 app manifest 要求。
- 如果 app 有构建步骤，把它收口到 app-local `reload.sh`；不要让构建逻辑散落到 shell、Router 或人工终端步骤里。
- 用 compile/test failures 驱动调用点有意识迁移。

收尾前：

- 跑 focused Workbench tests。
- 如果 app/runtime contract 变化，同步 `docs/dev/progress/YYYY-MM-DD.md` 和 `docs/dev/progress/CURRENT.md`。
- 如果形成稳定架构结论，提升到 `docs/dev/findings/`。
- 新增 permissions 和 bridge methods 时，同步本文档或当前 phase plan。
