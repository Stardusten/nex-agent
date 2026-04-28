# Phase 18B Workbench Static Iframe Apps

## 当前状态

Phase 18 已经把 Workbench 从 0 推到可用原型：

- `workspace/workbench/apps/<id>/nex.app.json` 是 app manifest 真相源。
- `Nex.Agent.Workbench.Store` / `AppManifest` 可以读写、校验、列出 app。
- `Runtime.Snapshot.workbench` 暴露 app catalog、diagnostics 和 runtime config。
- `Nex.Agent.Workbench.Permissions` 拥有 `workspace/workbench/permissions.json` owner grant 真相源。
- `Workbench.Server` / `Router` 提供 loopback HTTP API。
- `priv/workbench/shell.html` 是当前静态 shell，已有 Observability、Self Evolution、Sessions、Configuration 四个系统视图。
- shell 已支持窄屏 `Menu` / `Detail` 抽屉。
- `/app-frame/:id` 当前只是 manifest placeholder，不会加载真实 app 前端。

当前缺口：

- Workbench app 还不能像普通静态网页一样直接打开 `index.html`。
- iframe app 还不能通过 host-mediated SDK bridge 调用 Nex 能力。
- app 改完后没有明确的 reload 生效流程。
- 旧设计里提到的 `runtime.kind`、Vite/build pipeline、`workbench_app` 写文件工具过早；18B 不做这些。

## 完成后必须达到的结果

Phase 18B 结束时仓库必须满足：

1. Workbench app 是 workspace 下的静态前端文件，不是 core system view。
2. manifest 不再要求 `runtime` 字段；第一版唯一运行方式就是 static HTML inside sandboxed iframe。
3. agent 创建和修改 app 文件只使用现有 `find` / `read` / `apply_patch` 文件主链，不新增 `workbench_app`、`write_file`、`save_manifest` 或其他平行写文件工具。
4. `GET /app-frame/:id` 读取 app manifest 的 `entry` 文件，注入 `window.Nex` SDK bootstrap，并返回给 iframe。
5. `GET /app-assets/:id/<relative_path>` 只服务该 app 目录下的静态资源，不能读出 app 目录，也不能读 `nex.app.json`。
6. shell 提供手动 Reload 当前 app 的按钮；切换 app 时也会重新加载 iframe。18B 不实现 Vite、HMR、自动 build 或 Node dev server。
7. iframe app 能通过 `window.Nex.call(...)` 发起 host-mediated bridge call。
8. host shell 只接受来自当前 app iframe `contentWindow` 的 bridge message，并为请求绑定当前 app id。
9. backend 通过 `Nex.Agent.Workbench.Bridge` 执行固定 method allowlist，不暴露 arbitrary HTTP、arbitrary file path 或 arbitrary tool call。
10. 每个 bridge call 都必须先经过 `Permissions.check/3`，同时满足 manifest declared permission 和 owner granted permission。
11. bridge started / finished / failed / denied 都写 ControlPlane observations。
12. Workbench core CODE 更新仍走现有 `apply_patch` / `self_update`；Workbench app artifact 更新只写 workspace app 文件，刷新 iframe 后生效，不需要 `self_update deploy`。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/designs/2026-04-28-workbench-app-runtime.md`
- `docs/dev/designs/2026-04-28-workbench-app-authoring-guide.md`
- `docs/dev/task-plan/phase18-workbench-app-runtime.md`
- `docs/dev/task-plan/phase10e-code-editing-toolchain-reset.md`
- `docs/dev/findings/2026-04-27-file-access-allowed-roots.md`
- `lib/nex/agent/workbench/app_manifest.ex`
- `lib/nex/agent/workbench/store.ex`
- `lib/nex/agent/workbench/permissions.ex`
- `lib/nex/agent/workbench/router.ex`
- `lib/nex/agent/workbench/server.ex`
- `lib/nex/agent/workbench/shell.ex`
- `priv/workbench/shell.html`
- `lib/nex/agent/security.ex`
- `lib/nex/agent/control_plane/log.ex`
- `lib/nex/agent/control_plane/query.ex`
- `lib/nex/agent/tool/read.ex`
- `lib/nex/agent/tool/find.ex`
- `lib/nex/agent/tool/apply_patch.ex`
- `test/nex/agent/workbench/server_test.exs`
- `test/nex/agent/workbench/store_test.exs`
- `test/nex/agent/workbench/permissions_test.exs`
- `test/nex/agent/apply_patch_tool_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. 18B 覆盖旧设计中关于 Vite/build pipeline、`runtime.kind`、`runtime.sandbox`、`workbench_app` tool 的内容。旧设计文档可作为背景阅读，但执行以本 plan 为准。

2. app 文件结构：

```text
<workspace>/workbench/apps/<id>/nex.app.json
<workspace>/workbench/apps/<id>/index.html
<workspace>/workbench/apps/<id>/app.js
<workspace>/workbench/apps/<id>/style.css
<workspace>/workbench/apps/<id>/assets/**
```

Only `nex.app.json` is required for catalog visibility. `entry` defaults to `index.html` when omitted.

3. manifest 最小 shape：

```elixir
%{
  "id" => String.t(),
  "title" => String.t(),
  optional("version") => String.t(),
  optional("entry") => String.t(),
  optional("permissions") => [String.t()],
  optional("metadata") => map()
}
```

18B must remove `runtime` from the required manifest contract. If older manifests still contain `runtime`, implementation may preserve it as ignored metadata for migration, but new docs/tests must not require or display it as a meaningful app setting.

4. entry contract：

```text
default: index.html
allowed: relative file path under app dir
rejected: empty string, absolute path, .. segment, directory, missing file
```

5. app frame route:

```text
GET /app-frame/:id
```

returns the app entry HTML with SDK bootstrap injection. If the manifest is invalid or entry is missing, return a bounded placeholder error page inside the iframe.

6. app asset route:

```text
GET /app-assets/:id/<relative_path>
```

serves static files under `<workspace>/workbench/apps/<id>/` only. The route rejects:

```text
empty path
absolute path
.. segment
directories
files outside app dir
nex.app.json
files larger than 2MB in the first implementation
unknown app id
```

7. supported asset content types:

```text
.html text/html
.js application/javascript
.css text/css
.json application/json
.svg image/svg+xml
.png image/png
.jpg/.jpeg image/jpeg
.webp image/webp
.txt text/plain
fallback application/octet-stream
```

8. iframe bridge request shape:

```javascript
{
  nex: "workbench.bridge.request",
  version: 1,
  call_id: "uuid-or-random-string",
  method: "observe.query",
  params: {}
}
```

The iframe must not be trusted to provide `app_id`. Host shell derives app id from the selected iframe it created.

9. iframe bridge response shape:

```javascript
{
  nex: "workbench.bridge.response",
  version: 1,
  call_id: "same-call-id",
  ok: true,
  result: {}
}
```

or:

```javascript
{
  nex: "workbench.bridge.response",
  version: 1,
  call_id: "same-call-id",
  ok: false,
  error: {
    code: "permission_denied",
    message: "bounded message"
  }
}
```

10. backend bridge HTTP route:

```text
POST /api/workbench/bridge/:app_id/call
```

Body uses the iframe request shape minus `nex` if called by host. Router must ignore any `app_id` field in the body.

11. initial bridge method allowlist:

```elixir
%{
  "permissions.current" => %{
    permission: "permissions:read",
    params: %{}
  },
  "observe.summary" => %{
    permission: "observe:read",
    params: %{"limit" => optional_pos_integer}
  },
  "observe.query" => %{
    permission: "observe:read",
    params: %{
      "tag" => optional_string,
      "tag_prefix" => optional_string,
      "kind" => optional_string,
      "level" => optional_string,
      "run_id" => optional_string,
      "session_key" => optional_string,
      "channel" => optional_string,
      "chat_id" => optional_string,
      "tool" => optional_string,
      "tool_call_id" => optional_string,
      "tool_name" => optional_string,
      "trace_id" => optional_string,
      "query" => optional_string,
      "since" => optional_string,
      "limit" => pos_integer()
    }
  }
}
```

12. app runtime storage is not part of 18B. A first app may use browser `localStorage` for prototype state. If later app state must be durable in workspace, add a separate capability with an explicit owner-reviewed contract.

13. app authoring contract:

```text
discover files: find
inspect files: read
modify files: apply_patch
activate app change: reload iframe
activate core CODE change: self_update deploy
```

No new tool may duplicate `read`, `find`, `apply_patch`, or `self_update`.

14. ControlPlane tags for bridge and serving:

```text
workbench.bridge.call.started
workbench.bridge.call.finished
workbench.bridge.call.failed
workbench.bridge.call.denied
workbench.app.frame.served
workbench.app.frame.failed
workbench.app.asset.served
workbench.app.asset.failed
```

15. Domain app boundary:

18B must not freeze a notes root, stock schema, project board schema, storage schema, or other domain-specific app data model into core Workbench. Domain apps are ordinary static app files under `workspace/workbench/apps/<id>/`.

## 执行顺序 / stage 依赖

- Stage 1：Manifest contract simplification。
- Stage 2：Static app frame and asset serving。
- Stage 3：Manual reload flow in shell。
- Stage 4：Backend bridge core and method allowlist。
- Stage 5：Host SDK bridge in `shell.html` and iframe bootstrap。
- Stage 6：Static fixture app smoke test and docs alignment。

Stage 2 依赖 Stage 1。
Stage 3 依赖 Stage 2。
Stage 4 可与 Stage 2 并行，但 Stage 5 依赖 Stage 4。
Stage 6 依赖 Stage 2、Stage 3、Stage 5。

## Stage 1

### 前置检查

- 读清 `AppManifest` 当前对 `runtime.kind` / `runtime.sandbox` 的校验。
- 读清 `Store.load_all/1` 对 invalid manifest diagnostics 的处理。
- 确认 existing tests 中哪些 fixture 还带 `runtime`。

### 这一步改哪里

- `lib/nex/agent/workbench/app_manifest.ex`
- `test/nex/agent/workbench/store_test.exs`
- `test/nex/agent/workbench/permissions_test.exs`
- `test/nex/agent/workbench/server_test.exs`
- `docs/dev/designs/2026-04-28-workbench-app-authoring-guide.md`

### 这一步要做

- 从 required manifest contract 删除 `runtime`。
- 支持 `entry` 默认值 `index.html`。
- 校验 `entry` 是安全相对路径。
- manifest view 里不再把 `runtime` 显示成必须配置项。
- 更新测试 fixture，不再要求新 app manifest 写：

```json
"runtime": {"kind": "...", "sandbox": "..."}
```

### 实施注意事项

- 不为了兼容旧计划继续要求 `runtime.kind=static`。
- 不把 `runtime` 重命名成另一个同义配置项。
- invalid manifest 仍然只进入 diagnostics，不应导致 runtime reload 失败。

### 本 stage 验收

- 不含 `runtime` 的 manifest 能通过校验。
- `entry` 缺省时返回 `index.html`。
- `entry` 为绝对路径、`..`、空字符串时被拒绝。
- 带旧 `runtime` 字段的 manifest 不会因为这个字段本身失败；它只被当作 ignored extra field。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/workbench/store_test.exs test/nex/agent/workbench/permissions_test.exs
```

## Stage 2

### 前置检查

- Stage 1 通过。
- `Workbench.Router.dispatch/4` 当前 route tests 稳定。

### 这一步改哪里

- `lib/nex/agent/workbench/router.ex`
- `lib/nex/agent/workbench/shell.ex`
- 新增 `lib/nex/agent/workbench/assets.ex`
- `test/nex/agent/workbench/server_test.exs`
- 新增 `test/nex/agent/workbench/assets_test.exs`

### 这一步要做

- 增加 route：

```text
GET /app-assets/:app_id/*
```

- 修改 `GET /app-frame/:id`：
  - valid manifest + existing entry：读取 app entry HTML，注入 SDK bootstrap，返回 iframe page。
  - invalid manifest / missing entry：返回 bounded placeholder error page。
- 实现 `Workbench.Assets`：
  - resolve app dir。
  - validate entry path。
  - validate asset path。
  - infer content type。
  - enforce size cap。
- frame/asset serving 写 ControlPlane observation。

### 实施注意事项

- `/app-assets` 不能读取 `nex.app.json`。
- `/app-assets` 不能读取 `workspace/workbench/permissions.json`、ControlPlane、repo CODE 或 app dir 外文件。
- frame route 只注入 SDK bootstrap，不把 secret、raw config、workspace absolute path 暴露给 iframe。
- 不引入 Vite/build/dist 概念。

### 本 stage 验收

- `workspace/workbench/apps/demo/index.html` 能通过 `/app-frame/demo` 打开。
- `index.html` 里引用 `/app-assets/demo/app.js` 和 `/app-assets/demo/style.css` 可正常加载。
- missing entry 返回 iframe 内 bounded error，不返回 500。
- `../`、绝对路径、`nex.app.json`、超大文件被拒绝。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/workbench/assets_test.exs test/nex/agent/workbench/server_test.exs
```

## Stage 3

### 前置检查

- Stage 2 可打开真实 static app entry。
- shell 页面可正常加载 Observability / Configuration / Sessions / Self Evolution。

### 这一步改哪里

- `priv/workbench/shell.html`
- `test/nex/agent/workbench/server_test.exs`
- 可选新增 `test/nex/agent/workbench/shell_test.exs`

### 这一步要做

- 在 app view 的 toolbar 增加 `Reload` 当前 app 按钮。
- 点击 `Reload` 时只刷新当前 app iframe，不刷新整个 Workbench shell。
- 切换 app 时给 iframe URL 加 cache-busting query：

```text
/app-frame/<id>?v=<timestamp-or-counter>
```

- 保持当前左侧 app list / 右侧 inspector 行为。

### 实施注意事项

- 不实现自动文件 watcher。
- 不实现 HMR。
- 不需要 websocket。
- reload 不应清空 Workbench shell 当前选中的 app、inspector 状态和 system view 状态。

### 本 stage 验收

- 修改 app 文件后，用户点击 `Reload` 可以看到 iframe 新内容。
- 切换 app 会加载对应 iframe。
- system views 不显示无意义的 app reload 控制。
- `node` 能解析 shell script。

### 本 stage 验证

```bash
node - <<'NODE'
const fs = require('fs');
const html = fs.readFileSync('priv/workbench/shell.html', 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
for (const script of scripts) new Function(script);
console.log(`parsed ${scripts.length} script block(s)`);
NODE
/opt/homebrew/bin/mix test test/nex/agent/workbench/server_test.exs
```

## Stage 4

### 前置检查

- `test/nex/agent/workbench/permissions_test.exs` 通过。
- `Nex.Agent.Workbench.Permissions.check/3` 已确认会写 denied observation。
- `ControlPlane.Store.query/2` 已支持 `trace_id`、`tool`、`tool_call_id`、`tool_name` filters。

### 这一步改哪里

- 新增 `lib/nex/agent/workbench/bridge.ex`
- `lib/nex/agent/workbench/router.ex`
- 新增 `test/nex/agent/workbench/bridge_test.exs`
- `test/nex/agent/workbench/server_test.exs`

### 这一步要做

- 新增 route：

```text
POST /api/workbench/bridge/:app_id/call
```

- 新增 `Nex.Agent.Workbench.Bridge.call(app_id, request, snapshot_or_opts)`。
- 规范化 request：

```elixir
%{
  "call_id" => String.t(),
  "method" => String.t(),
  "params" => map()
}
```

- 对 method 做固定 allowlist dispatch。
- 对 method 要求的 permission 调 `Permissions.check/3`。
- 实现 `permissions.current`、`observe.summary`、`observe.query` 三个只读方法。
- 所有返回值必须是 JSON-safe map/list/string/number/boolean/nil。
- started / finished / failed / denied 写 ControlPlane。
- error message bounded 到 500 字符。

### 实施注意事项

- 不在 `Router` 里写 method 业务逻辑；Router 只解码 HTTP 并调用 Bridge。
- 不信任 request body 里的 app id。
- 不允许 bridge method 透传任意 module/function/tool。
- `observe.query` 必须复用当前 Workbench observe allowlist，不能接受文件路径。
- 不实现 app storage、notes、stock、arbitrary HTTP。

### 本 stage 验收

- app 未声明 permission 时 bridge 返回 denied。
- app 声明但 owner 未 grant 时 bridge 返回 denied。
- owner grant 后 `observe.summary` / `observe.query` 可用。
- `permissions.current` 返回 declared/granted/denied/stale view。
- 每个成功和失败路径都有 ControlPlane observation。
- malformed JSON 返回 400，不返回 500。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/workbench/bridge_test.exs test/nex/agent/workbench/permissions_test.exs test/nex/agent/workbench/server_test.exs
```

## Stage 5

### 前置检查

- Stage 2 app frame 可注入 bootstrap。
- Stage 4 bridge route 可用。

### 这一步改哪里

- `priv/workbench/shell.html`
- `lib/nex/agent/workbench/shell.ex`
- `test/nex/agent/workbench/server_test.exs`
- 可选新增 `test/nex/agent/workbench/shell_test.exs`

### 这一步要做

- 在 host shell 中为当前 iframe 建立 SDK bridge handler。
- handler 只接受当前 iframe `contentWindow` 发来的 request。
- handler 为请求补 app id，并调用 `/api/workbench/bridge/:app_id/call`。
- handler 将结果按冻结 response shape 发回 iframe。
- 每个 request 有 timeout，建议 30s。
- 注入到 iframe 的 bootstrap 提供：

```javascript
window.Nex.call(method, params, options)
window.Nex.permissions()
window.Nex.observe.query(filters)
window.Nex.observe.summary(params)
```

### 实施注意事项

- iframe app 不拿 backend token。
- 不用 `*` 以外 origin 做虚假安全假设；loopback same-origin 下主要校验 `event.source` 和当前 app id。
- 不把 user secret、raw config、full workspace path 暴露给 iframe。
- 不暴露 `window.Nex.storage.*`、`window.Nex.notes.*`、`window.Nex.fetch.*`。
- app 可以用浏览器 localStorage 做第一版 UI 状态；持久 workspace storage 另开能力设计。

### 本 stage 验收

- 一个 fixture app 可调用 `window.Nex.permissions()` 并收到结果。
- 非当前 iframe source 的 message 被忽略。
- malformed message 被忽略或返回 bounded error，不触发 backend call。
- app 切换后旧 iframe 的 pending result 不写进新 iframe。
- `node` 能解析 shell script。

### 本 stage 验证

```bash
node - <<'NODE'
const fs = require('fs');
const html = fs.readFileSync('priv/workbench/shell.html', 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
for (const script of scripts) new Function(script);
console.log(`parsed ${scripts.length} script block(s)`);
NODE
/opt/homebrew/bin/mix test test/nex/agent/workbench/bridge_test.exs test/nex/agent/workbench/server_test.exs
```

## Stage 6

### 前置检查

- Stage 5 host SDK bridge 可用。
- Existing `read` / `find` / `apply_patch` tests 通过。

### 这一步改哪里

- `docs/dev/designs/2026-04-28-workbench-app-authoring-guide.md`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/2026-04-28.md`
- 可选新增 static fixture under tests only。

### 这一步要做

- 文档中明确新 app 开发流程：

```text
create app files with apply_patch
open Workbench
select app
edit app files with apply_patch
click Reload
repeat
```

- 给出最小 app manifest 示例：

```json
{
  "id": "hello",
  "title": "Hello",
  "entry": "index.html",
  "permissions": ["permissions:read"]
}
```

- 给出最小 static app 示例：

```text
index.html
app.js
style.css
```

- 对齐文档：18B 不要求 `runtime`、Vite、build、HMR、`workbench_app`。

### 实施注意事项

- 不把 fixture app 当成产品 app。
- 不把 Notes、stock dashboard、timeline 写进 Phase 18B 硬验收。
- 不在 app 中 fetch 私有 backend API；必须走 SDK。
- app 不读取或展示 workspace 绝对路径。

### 本 stage 验收

- 新 agent 只读 docs 就能知道如何创建静态 Workbench app。
- 文档没有继续要求 manifest 写 `runtime`。
- 文档没有继续要求 `workbench_app` 写文件或 build。
- fixture app 可被 `/app-frame/:id` 打开，并能调用 `window.Nex.permissions()`。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/workbench/store_test.exs test/nex/agent/workbench/assets_test.exs test/nex/agent/workbench/bridge_test.exs test/nex/agent/workbench/server_test.exs
/opt/homebrew/bin/mix test test/nex/agent/apply_patch_tool_test.exs test/nex/agent/tool_alignment_test.exs
```

## Review Fail 条件

- 新增 `workbench_app`、`write_file`、`save_manifest`、`delete_file` 或任何平行文件编辑 tool。
- manifest 仍要求 `runtime` / `runtime.kind` / `runtime.sandbox`。
- 18B 引入 Vite、Node dev server、HMR、build pipeline 或 `dist/` hard requirement。
- app iframe 可以直接调用 backend HTTP API 绕过 host bridge。
- bridge 信任 iframe 提供的 `app_id`。
- bridge 暴露 arbitrary tool call、arbitrary HTTP fetch、arbitrary filesystem path。
- manifest declared permission 被当作 owner granted permission。
- `/app-assets` 可以读出 app dir，或可以读取 `nex.app.json`。
- `/app-frame` 或 bootstrap 暴露 secret、raw config、workspace absolute path。
- 18B 把 Notes、stock dashboard、timeline 等 domain app 写成 core system view 或 core bridge method。
- bridge failure / permission denied 不写 ControlPlane。
- 改 Workbench app artifact 后要求 `self_update deploy` 才能生效。
- 测试只覆盖 happy path，不覆盖 permission denied、path escape、missing entry、malformed message。
