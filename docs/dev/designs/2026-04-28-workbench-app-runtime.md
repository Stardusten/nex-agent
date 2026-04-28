# 2026-04-28 Workbench App Runtime Design

## 背景

用户希望 NexAgent 有一个控制台，但这个控制台不是普通 Admin UI。它应该是一个本地优先、可自进化、可长出新应用形态的工作台：

- 用户可以在对话中要求新增一个股票追踪 tab。
- 用户也可以通过同一机制得到一个类似在线 Obsidian 的笔记编辑工具。
- 未来还可以出现项目看板、ControlPlane 时间线、任务面板、研究数据库、个人仪表盘等。

因此控制台不能被设计成固定页面加少量可配置 widget。更准确的产品模型是：

```text
NexAgent Workbench = local-first app host + capability-gated runtime + agent-editable app workspace
```

## 核心结论

采用 **本地 Workbench App Runtime** 路线：

```text
127.0.0.1:50051 / SSH tunnel only
        |
Workbench server
        |
Web shell: launcher / tabs / permissions / chat / observations
        |
Sandboxed iframe app instances
        |
Agent-generated apps under workspace/workbench/apps/<id>/
        |
Nex SDK: notes / files / tools / observe / sessions / tasks
        |
NexAgent Runtime / ControlPlane / Tools / Workspace
```

Workbench shell 只负责宿主能力：

- 加载 app manifest
- 管理 tab / layout / app instance
- 执行权限检查
- 代理 app 对 Nex 后端的调用
- 展示 agent chat、权限审批、运行观测和错误

具体功能由 app 生长出来：

- 股票追踪是一个 app。
- 在线笔记是一个 app。
- ControlPlane timeline 是一个 app。
- 每个 app 可以由 agent 创建、修改、构建、重载。

## 技术选型

### 前端宿主

第一版使用 Vite + React + TypeScript。

原因：

- 生态最大，编辑器、图表、表格、拖拽、MDX、状态管理都容易集成。
- Vite 的 HMR 和 library build 适合 agent 频繁编辑小 app。
- React 作为默认 app template 足够通用；后续可以支持 Vue/Svelte，但不要在第一版扩散。

### App 隔离

每个 Workbench app 运行在 sandboxed iframe 内。

app 不能直接拿全权限 API token，也不能直接访问所有 NexAgent 后端能力。app 只能通过 `postMessage` 调用 host 注入的 Nex SDK bridge。host 根据 app manifest 中声明的 capability 和 owner 授权结果决定是否转发。

### 后端 API

服务端绑定本机端口：

```text
127.0.0.1:50051
```

端口和启用状态属于 runtime config contract，而不是 server 私有常量。当前稳定入口放在：

```json
{
  "gateway": {
    "workbench": {
      "enabled": false,
      "host": "127.0.0.1",
      "port": 50051
    }
  }
}
```

`Nex.Agent.Config.workbench_runtime/1` 负责规范化，`Nex.Agent.Runtime.Snapshot.workbench.runtime` 负责投影给长期进程。Workbench server 只能从 Runtime snapshot 读端口，不直接读取 config 文件。

推荐访问模型：

- 默认只监听 loopback。
- 远程访问通过 SSH port forwarding。
- 不把 Workbench 暴露到公网。
- 后续可配置防火墙和 allowlist，但不把网络边界当成唯一安全边界。

浏览器侧不直接使用 native gRPC。第一版后端协议采用：

- HTTP JSON for unary commands
- WebSocket or Server-Sent Events for events / logs / app reload / observation tail

之后如果需要强 IDL 和生成客户端，可以升级到 Connect-style RPC / gRPC-Web-compatible API，但不要让第一版被 proto/tooling 阻塞。

### 笔记编辑能力

第一版在线 Obsidian-like app 使用 Markdown + CodeMirror 6：

- 文件真相源仍在 workspace。
- editor state 由 app 管理。
- 保存通过 Workbench SDK 的 bounded file API。
- 双链/标签/backlink/search 可逐步增加。

如果需要多人/多窗口实时协作，再接 Yjs：

- Yjs document 作为编辑 CRDT。
- 后端持久化 Yjs update log 或定期 materialize Markdown。
- Awareness/presence 不进入长期真相源。

### 图表和看板能力

股票看板、数据探索类 app 优先使用现成前端库：

- TanStack Table for dense tables
- Observable Plot / ECharts for charts
- app 自己通过 tool/data source 拉数据

不要把图表 DSL 做进核心 Workbench。核心只定义 app 权限和 data bridge。

## Workspace 真相源

Workbench 的 durable state 放在 workspace 内：

```text
workspace/
  workbench/
    apps/
      notes/
        nex.app.json
        package.json
        src/App.tsx
      stock-dashboard/
        nex.app.json
        package.json
        src/App.tsx
    layout.json
    permissions.json
    builds/
```

`nex.app.json` 是 app 的最小 contract：

```json
{
  "id": "stock-dashboard",
  "title": "Stocks",
  "version": "0.1.0",
  "runtime": {
    "kind": "vite-react",
    "sandbox": "iframe"
  },
  "entry": "src/App.tsx",
  "permissions": [
    "tools:call:stock_quote",
    "observe:read"
  ],
  "metadata": {}
}
```

`layout.json` 只记录 shell 布局和打开的 app，不记录 app 内部业务状态。

`permissions.json` 记录 owner 授权，不由 app 自己写入。

## Capability Model

Workbench 的安全模型不是“端口安全就够了”，而是三层叠加：

1. 网络边界：loopback / SSH tunnel / firewall。
2. 进程和浏览器边界：sandboxed iframe + host bridge。
3. Nex capability 边界：manifest 声明 + owner 授权 + backend enforcement。

permission 字符串采用可读前缀：

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

app 只能请求自己 manifest 声明且 owner 已授权的 capability。所有调用必须写 ControlPlane observation，例如：

```text
workbench.app.call.started
workbench.app.call.finished
workbench.app.call.failed
workbench.permission.granted
workbench.permission.denied
workbench.app.built
workbench.app.loaded
```

## Agent 自进化路径

用户说：

```text
在控制台里加一个股票追踪 tab，显示我关注的所有股票
```

期望流程：

1. agent 判断这是 Workbench app 变更。
2. 如果已有 stock-dashboard app，则修改它；否则创建新 app。
3. 如果缺数据能力，agent 创建或接入确定性 tool。
4. agent 生成 `nex.app.json`、前端源码、必要 package 配置。
5. Workbench build/check 通过后生成 candidate。
6. owner 批准权限和 app 安装。
7. shell 加载新 app。
8. 所有生命周期写入 ControlPlane。

这对应 NexAgent 六层：

- `USER`：用户关注哪些股票、默认展示偏好。
- `MEMORY`：股票 watchlist、长期配置事实。
- `SKILL`：创建/维护 Workbench app 的复用流程。
- `TOOL`：行情查询、文件读写、构建、权限审批等确定性能力。
- `CODE`：Workbench shell/server/SDK 本身的实现。

app 源码不是 `CODE` 层主框架实现，而是 workspace app artifact。只有修改 Workbench core/server/SDK 时才进入 CODE self-update 主链。

## 与现有系统的关系

Workbench 不替代现有聊天入口。它是新的 surface：

- Feishu / Discord 仍是 chat gateways。
- Workbench chat 是本地 web surface。
- session routing 仍通过 `channel:chat_id` 或后续明确的 console/workbench session key。
- ControlPlane 仍是运行观测真相源。
- Runtime snapshot 仍是配置/prompt/tools/skills/commands 的统一入口。

Workbench 不能维护一套平行 Admin state。Admin/observe/evolution candidate 等都必须读现有 ControlPlane 和 runtime 主链。

## 不采用的路线

### 固定 LiveView Admin

LiveView 很适合当前 Admin / realtime status，但不适合作为 agent 可生成任意复杂应用的宿主。把所有功能做进 LiveView 会把 Workbench 限制成“更多后台页面”。

### 直接暴露全权限 local API

只绑定 `127.0.0.1:50051` 不足以保护 workspace。恶意或错误 app 一旦拿到全权限 API，就能误删文件、乱调用工具或泄漏敏感信息。必须有 app-level capability enforcement。

### 第一版就做桌面壳

Tauri/Electron 可以后置。先让 local web + SSH tunnel 模型成立。桌面包装不应影响 core runtime contract。

## 开放问题

1. Workbench app build 是否由 Elixir 调 `npm`，还是由独立 Node supervisor 管理？
2. app dependency 安装是否允许联网，还是必须走 owner-approved package add？
3. app permission grant 的 UX 是聊天审批、Workbench 内审批，还是二者都支持？
4. 是否需要 per-app resource quota：build time、bundle size、tool call rate？
5. notes app 的第一版是纯 Markdown 文件，还是直接引入 Yjs update log？

## 第一阶段切入点

先落地不依赖浏览器和 Node 的底座：

- `workspace/workbench/` 目录进入 Workspace known dirs。
- 定义并验证 `nex.app.json` manifest contract。
- 提供 Workbench Store 读取/写入/list app。
- 将 manifest diagnostics 设计成后续 Runtime snapshot / Workbench shell 可消费的 shape。

这样后续不管 server 和 frontend 选型细节如何变化，app durable state 和权限声明都不会漂移。
