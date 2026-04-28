# Phase 18 Workbench App Runtime

## 当前状态

NexAgent 当前已有：

- Runtime snapshot 作为配置、prompt、tools、skills、commands 的统一真相源。
- ControlPlane 作为运行观测和 evolution evidence 的机器真相源。
- Admin 模块可以投影 runtime、sessions、skills、memory、tasks、evolution、code 状态。
- Evolution candidate 已收口到 owner-approved execution lane。

但当前没有一个本地 web workbench：

- 没有 `workspace/workbench/` durable state contract。
- 没有 agent-editable app manifest。
- 没有 Workbench app 权限模型。
- 没有 loopback-only web surface。
- 没有 sandboxed app host / SDK bridge。

## 完成后必须达到的结果

Phase 18 结束时仓库必须满足：

1. Workbench 被定义为新的本地 surface，不是 Admin 平行状态系统。
2. `workspace/workbench/apps/<id>/nex.app.json` 是 Workbench app 的 durable manifest 真相源。
3. `Nex.Agent.Workbench.Store` 可以读取、校验、写入、列出 app manifests，并返回 bounded diagnostics。
4. Runtime snapshot 或等价统一入口能暴露 Workbench app catalog 和 diagnostics。
5. Workbench server 只绑定 loopback，默认端口 `50051`，提供最小 HTTP JSON API。
6. Workbench shell 能列出 app、打开 sandboxed iframe app、显示权限状态和错误。
7. app 对 Nex 能力的调用只能通过 host SDK bridge，后端按 capability grant 执行。
8. 所有 app lifecycle、permission、API bridge 调用写 ControlPlane observation。
9. 第一版至少内置或生成一个 notes app 和一个 stock-dashboard demo app。
10. 不引入平行 deploy/self-update 主链；Workbench core CODE 改动仍走现有 `apply_patch` / `self_update`。

## 开工前必须先看的代码路径

- `docs/dev/designs/2026-04-28-workbench-app-runtime.md`
- `docs/dev/task-plan/phase13-control-plane-observability.md`
- `docs/dev/task-plan/phase13e-evolution-control-plane-consumption.md`
- `docs/dev/task-plan/phase14-owner-approved-evolution-execution.md`
- `lib/nex/agent/workspace.ex`
- `lib/nex/agent/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/admin.ex`
- `lib/nex/agent/control_plane/log.ex`
- `lib/nex/agent/control_plane/query.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/security.ex`
- `lib/nex/agent/tool/apply_patch.ex`
- `lib/nex/agent/tool/custom_tools.ex`
- `mix.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. Workbench app manifest 最小 shape 冻结为：

```elixir
%{
  "id" => String.t(),
  "title" => String.t(),
  "version" => String.t(),
  "runtime" => %{
    "kind" => "vite-react",
    "sandbox" => "iframe"
  },
  "entry" => String.t(),
  "permissions" => [String.t()],
  "metadata" => map()
}
```

2. Manifest 路径冻结为：

```text
<workspace>/workbench/apps/<id>/nex.app.json
```

3. app id contract：

```text
regex: ^[a-z][a-z0-9_-]{1,63}$
```

id 是路径段，不允许 `/`、`.`、空白、大小写漂移或 URL 编码语义。

4. entry contract：

```text
relative path only
must not be empty
must not start with /
must not contain .. path segment
```

第一版推荐 `src/App.tsx`，但 manifest validator 不把 React 文件后缀写死。

5. permission 字符串 contract：

```text
non-empty string
max length: 160
must not contain control characters
```

具体语义由 permission evaluator stage 冻结；Stage 1 只做 shape 校验。

6. Workbench durable state 路径冻结：

```text
<workspace>/workbench/apps/
<workspace>/workbench/layout.json
<workspace>/workbench/permissions.json
<workspace>/workbench/builds/
```

7. Workbench server 网络边界：

```text
default host: 127.0.0.1
default port: 50051
public bind requires explicit config in a later phase
```

Stage 18 不允许默认监听 `0.0.0.0`。

端口必须从 runtime config 进入 Runtime snapshot 后再被 server 消费：

```elixir
Config.workbench_runtime(config) == %{
  "enabled" => boolean(),
  "host" => "127.0.0.1",
  "port" => pos_integer()
}

snapshot.workbench.runtime == Config.workbench_runtime(snapshot.config)
```

不得在 `Workbench.Server` 内直接调用 `Config.load/0` 读取端口。

8. Browser app boundary：

```text
app iframe -> postMessage -> host shell -> Workbench API -> Nex runtime
```

app iframe 不直接持有 full backend token。

9. ControlPlane tags 冻结为点分字符串前缀：

```text
workbench.app.discovered
workbench.app.manifest.invalid
workbench.app.saved
workbench.app.loaded
workbench.app.built
workbench.app.build.failed
workbench.permission.granted
workbench.permission.denied
workbench.bridge.call.started
workbench.bridge.call.finished
workbench.bridge.call.failed
```

10. Workbench 不是 CODE deploy authority。

Workbench core/server/SDK 的 CODE 层改动仍然必须通过现有 CODE lane。workspace app artifact 的创建和修改属于 Workbench app artifact lane，不自动修改 `lib/nex/agent/**`。

## 执行顺序 / stage 依赖

- Stage 1：manifest/store/workspace foundation。
- Stage 2：Runtime/Admin read-only catalog projection。
- Stage 3：permission grant store and evaluator。
- Stage 4：loopback Workbench HTTP JSON API。
- Stage 5：Workbench shell prototype and sandbox iframe host。
- Stage 5B：Vite React shell upgrade。
- Stage 6：Nex SDK bridge and ControlPlane observations。
- Stage 7：notes app MVP。
- Stage 8：stock-dashboard demo app and tool integration.
- Stage 9：agent-facing Workbench app tool and owner approval flow。

Stage 2 依赖 Stage 1。
Stage 3 依赖 Stage 1。
Stage 4 依赖 Stage 2、Stage 3。
Stage 5 依赖 Stage 4。
Stage 5B 依赖 Stage 5。
Stage 6 依赖 Stage 4、Stage 5。
Stage 7 依赖 Stage 6。
Stage 8 依赖 Stage 6。
Stage 9 依赖 Stage 1、Stage 3、Stage 6。

## Stage 1

### 前置检查

- 当前没有已存在的 `lib/nex/agent/workbench/*` 实现。
- `Workspace.ensure!/1` 是 workspace 目录创建主入口。
- 不新增 web server dependency。

### 这一步改哪里

- `lib/nex/agent/workspace.ex`
- 新增 `lib/nex/agent/workbench/app_manifest.ex`
- 新增 `lib/nex/agent/workbench/store.ex`
- 新增 `test/nex/agent/workbench/store_test.exs`
- `docs/dev/task-plan/index.md`
- `docs/dev/designs/index.md`

### 这一步要做

- 将 `workbench` 加入 Workspace known dirs。
- 增加 `Workspace.workbench_dir/1`。
- 定义 `%Nex.Agent.Workbench.AppManifest{}` struct。
- 实现 manifest normalize / validate / to_map。
- 实现 Store：
  - `apps_dir/1`
  - `manifest_path/2`
  - `list/1`
  - `load_all/1`
  - `get/2`
  - `save/2`
- `save/2` 写入 `nex.app.json`，先写临时文件再 rename。
- list/load 读取 invalid manifest 时不崩溃，返回 diagnostics。

### 实施注意事项

- 不读取或写入安全禁区。
- 不把 Workbench app catalog 先塞进 Config。
- 不新增 JS/frontend 依赖。
- 不让 invalid manifest 让整个 Runtime 未来无法启动；diagnostic 必须 bounded。

### 本 stage 验收

- 临时 workspace 初始化后存在 `workbench/`。
- 保存一个合法 manifest 后可以 list/get。
- manifest 按 id 排序。
- invalid id / escaping entry 被拒绝。
- invalid manifest 文件出现在 diagnostics，不影响合法 app list。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/workbench/store_test.exs
```

## Stage 2

### 前置检查

- Stage 1 tests pass。
- Workbench Store 返回 stable app maps 和 diagnostics。

### 这一步改哪里

- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/runtime.ex`
- `lib/nex/agent/admin.ex`
- `test/nex/agent/runtime_test.exs`
- `test/nex/agent/admin_test.exs`

### 这一步要做

- Runtime snapshot 增加 `workbench` section：

```elixir
%{
  apps: [map()],
  diagnostics: [map()],
  hash: String.t()
}
```

- Runtime reload 时读取 Workbench Store。
- Admin overview 增加 workbench summary。

### 实施注意事项

- Workbench app catalog 是 runtime-readable workspace artifact，不是 Config 顶层 shape。
- invalid manifest 不导致 snapshot build failed。

### 本 stage 验收

- Runtime snapshot 能看到 apps 和 diagnostics。
- 修改 app manifest 后 Runtime hash 改变。
- Admin overview 能展示 app count 和 diagnostics count。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/runtime_test.exs test/nex/agent/admin_test.exs
```

## Stage 3

### 前置检查

- Stage 1 manifest permission shape stable。

### 这一步改哪里

- 新增 `lib/nex/agent/workbench/permissions.ex`
- 新增 `test/nex/agent/workbench/permissions_test.exs`

### 这一步要做

- `permissions.json` 记录 app grants。
- 实现 grant/revoke/check/list。
- ControlPlane 记录 grant/deny observations。

### 实施注意事项

- app manifest 声明不等于已授权。
- grant store 不写进 manifest。

### 本 stage 验收

- 未授权 permission check 默认 deny。
- grant 只能针对 manifest 已声明 permission。
- revoke 后立即 deny。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/workbench/permissions_test.exs
```

## Stage 4

### 前置检查

- Stage 2/3 pass。

### 这一步改哪里

- 新增 `lib/nex/agent/workbench/server.ex`
- 新增 `lib/nex/agent/workbench/router.ex`
- 新增 `test/nex/agent/workbench/server_test.exs`

### 这一步要做

- 使用 OTP `:gen_tcp` 提供最小 HTTP JSON API，不新增 web server dependency。
- 默认监听 `127.0.0.1:50051`。
- 提供 JSON endpoints：
  - `GET /api/workbench/apps`
  - `GET /api/workbench/apps/:id`
  - `GET /api/workbench/permissions/:id`
  - `POST /api/workbench/permissions/:id/grant`
  - `POST /api/workbench/permissions/:id/revoke`
  - `GET /api/observe/summary`
  - `GET /api/observe/query`
  - `GET /api/workbench/sessions`
  - `GET /api/workbench/sessions/:session_key`
  - `POST /api/workbench/sessions/:session_key/stop`
  - `POST /api/workbench/sessions/:session_key/model`

### 实施注意事项

- 第一版不提供 public bind。
- API 不接受任意文件路径。
- 错误响应必须 bounded。

### 本 stage 验收

- server 启动后只绑定 loopback。
- API 能返回 app catalog 和 diagnostics。
- permission grant/revoke 可用。
- observe query 能按 tag prefix、run、session、channel、tool 和 level 做白名单过滤。
- session API 能列出持久 session 和 active owner run，stop 复用 run-control 主链，model 切换复用 session model override。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/workbench/server_test.exs
```

## Stage 5

### 前置检查

- Stage 4 API stable。

### 这一步改哪里

- 新增 `lib/nex/agent/workbench/shell.ex`
- 新增 `priv/workbench/shell.html`
- 更新 `lib/nex/agent/workbench/router.ex`
- 更新 `lib/nex/agent/workbench/server.ex`
- 更新 `test/nex/agent/workbench/server_test.exs`

### 这一步要做

- 先交付无构建链的静态 Workbench prototype。
- 左侧 app launcher / tabs。
- app iframe sandbox。
- API client。
- permission/error panel。
- observe summary panel。
- `GET /` 和 `GET /workbench` 返回 shell HTML。
- `GET /app-frame/:id` 返回第一版 sandbox frame，占位展示 manifest 信息。

### 实施注意事项

- shell 不直接执行 app code。
- app iframe sandbox 默认不允许 top navigation。
- shell UI 不是营销页，第一屏就是实际工作台。
- 本 stage 只是最小可用原型，不冻结最终 frontend stack。
- 不在本 stage 引入 Node/Vite 依赖。

### 本 stage 验收

- shell 能显示 apps。
- 点击 app 后 iframe 打开 app。
- invalid app 显示错误，不影响其他 app。
- permission grant/revoke 能在 inspector 中操作并刷新 ControlPlane observe panel。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/workbench/server_test.exs
```

## Stage 5B

### 前置检查

- Stage 5 static prototype 可用。
- Stage 4 API shape 没有因 shell 原型暴露出阻塞问题。

### 这一步改哪里

- 新增 `workbench-shell/` 或 `assets/workbench/`，最终路径在开工前冻结。
- 新增 shell build docs。
- 更新 `lib/nex/agent/workbench/shell.ex` 以服务构建产物。

### 这一步要做

- Vite React shell。
- 保留 Stage 5 已验证的 app launcher、iframe、permission/error/observe 面板语义。
- 增加 typed API client 和基础前端测试。

### 实施注意事项

- 不改变 Stage 4 HTTP API contract。
- 不让 React shell 直接读取 workspace 文件。
- build artifact 和 source path 要明确区分。

### 本 stage 验收

- build 后 shell 行为与 Stage 5 原型一致。
- 生产 shell 可以从 Workbench server 打开。
- app/permission/diagnostics/observe 四个面板均保留。

### 本 stage 验证

```bash
npm test -- --run
npm run build
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/workbench/server_test.exs
```

## Stage 6

### 前置检查

- Stage 5 shell 可以加载 iframe。

### 这一步改哪里

- Workbench shell SDK bridge files。
- Workbench server bridge endpoints。
- `lib/nex/agent/control_plane/*` call sites as needed。

### 这一步要做

- iframe app 通过 `postMessage` 调 host SDK。
- host 校验 origin/app id/capability。
- server 执行 bounded Nex calls。
- ControlPlane 写 bridge started/finished/failed。

### 实施注意事项

- app 不持有 backend token。
- bridge 不暴露 arbitrary tool call，必须按 permission 粒度收口。

### 本 stage 验收

- 未授权 app call 被拒绝并记录 observation。
- 已授权 call 成功并记录 observation。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/workbench
npm test -- --run
```

## Stage 7

### 前置检查

- Stage 6 bridge 可用。

### 这一步改哪里

- `workspace/workbench/apps/notes` template fixture or generator。
- notes app frontend。
- notes bridge endpoints。

### 这一步要做

- Markdown file list。
- CodeMirror editor。
- Save/load through Workbench SDK。
- Search/backlink 最小只读视图。

### 实施注意事项

- 文件访问必须复用 `Nex.Agent.Security` allowed roots。
- 不让 app 自己传任意绝对路径。

### 本 stage 验收

- 能创建/编辑/保存 workspace notes。
- 未授权 files write 被拒绝。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/workbench
npm test -- --run
```

## Stage 8

### 前置检查

- Stage 6 bridge 可调用 bounded tool/data source。

### 这一步改哪里

- stock-dashboard app template。
- stock quote data source/tool integration。
- tests for permission and bridge。

### 这一步要做

- watchlist config。
- quote table。
- chart panel。
- refresh action。

### 实施注意事项

- 不在 core Workbench 写死股票业务。
- 行情能力必须是 tool/data source，不是 iframe 直接抓公网。

### 本 stage 验收

- stock-dashboard app 可以显示 watchlist。
- 无 `tools:call:stock_quote` 权限时无法刷新。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/workbench
npm test -- --run
```

## Stage 9

### 前置检查

- Stage 1/3/6 已稳定。

### 这一步改哪里

- 新增 `lib/nex/agent/tool/workbench_app.ex`
- `lib/nex/agent/tool/registry.ex`
- `test/nex/agent/tool_alignment_test.exs`
- Workbench app generation tests。

### 这一步要做

- owner-facing tool：
  - `list`
  - `show`
  - `propose`
  - `approve`
  - `reject`
- app proposal 不自动 grant 权限。
- approve 后写 app files / permissions as owner-approved action。

### 实施注意事项

- follow-up/subagent surface 不暴露 approve/reject。
- 不绕过 existing file security。
- app proposal lifecycle 写 ControlPlane。

### 本 stage 验收

- 用户可以通过 agent 创建一个新 Workbench app proposal。
- owner 批准后 app 出现在 shell。
- 权限审批和文件写入均可追溯。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs test/nex/agent/workbench
```

## Review Fail 条件

- Workbench 默认监听 `0.0.0.0`。
- app iframe 直接持有 full backend token。
- app manifest 声明的 permission 被当成已授权 permission。
- 新增独立 app state 数据库并与 workspace manifest 平行维护。
- Workbench bridge 能绕过 `Nex.Agent.Security` 读写任意文件。
- Workbench core CODE 更新绕过 `self_update` deploy authority。
- ControlPlane 不记录 permission/app lifecycle/bridge failure。
- Admin/Runtime/Workbench 对 app catalog 使用三套不同读取逻辑。
- notes/stock demo 的业务逻辑写死进 core Workbench。
