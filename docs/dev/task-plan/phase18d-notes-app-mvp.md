# Phase 18D Workbench Notes App MVP

## 当前状态

Workbench 已经具备本地 loopback server、静态 iframe app host、manifest/permissions store、app frame/assets serving、手动 iframe reload、以及 `permissions.current` / `observe.summary` / `observe.query` 三个只读 SDK bridge method。

当前缺口：

- Workbench bridge 还没有 notes/file capability。
- Workbench config 没有 app-specific notes root contract。
- 还没有可打开本地 Markdown vault 的 notes app artifact。

## 完成后必须达到的结果

Phase 结束时必须满足：

1. Notes root 配置来自 `gateway.workbench.apps.notes.root`。
2. Notes app iframe 只能通过 `window.Nex.notes.*` 调用 bounded bridge method。
3. iframe 只传 `root_id` 和 vault-relative path，不传 absolute path。
4. backend 只允许访问配置 root 内的 Markdown 文件，拒绝 absolute path、`..`、root escape、symlink escape、非 Markdown 写入。
5. 写入使用 `base_revision` 做外部修改冲突检测，不静默覆盖。
6. bridge method 先经过 manifest declared permission 和 owner grant 检查。
7. notes list/read/write/search 写 ControlPlane observations。
8. 第一版编辑器使用 CodeMirror 6 + ProseMark，不做双栏 preview。
9. Notes app 是 workspace app artifact，不是 core system view。
10. 不新增通用 `write_file`、`workbench_app`、arbitrary tool call、arbitrary HTTP 或 arbitrary filesystem bridge。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/designs/2026-04-28-workbench-app-runtime.md`
- `docs/dev/designs/2026-04-28-workbench-app-authoring-guide.md`
- `docs/dev/task-plan/phase18b-workbench-sdk-bridge-and-app-authoring.md`
- `priv/skills/builtin/workbench-app-authoring/SKILL.md`
- `lib/nex/agent/config.ex`
- `lib/nex/agent/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/security.ex`
- `lib/nex/agent/workbench/bridge.ex`
- `lib/nex/agent/workbench/router.ex`
- `lib/nex/agent/workbench/permissions.ex`
- `lib/nex/agent/workbench/assets.ex`
- `priv/workbench/shell.html`
- `test/nex/agent/workbench/bridge_test.exs`
- `test/nex/agent/workbench/server_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. Config shape:

```json
{
  "gateway": {
    "workbench": {
      "enabled": true,
      "host": "127.0.0.1",
      "port": 50051,
      "apps": {
        "notes": {
          "root": "/Users/krisxin/Notes"
        }
      }
    }
  }
}
```

2. Notes app permissions:

```json
{
  "permissions": ["permissions:read", "notes:read", "notes:write"],
  "chrome": {"topbar": "hidden"}
}
```

3. Backend bridge methods:

```text
notes.roots.list -> notes:read
notes.files.list -> notes:read
notes.file.read  -> notes:read
notes.file.write -> notes:write
notes.file.delete -> notes:write
notes.search     -> notes:read
```

4. Root shape returned to iframe:

```elixir
%{
  "id" => "notes",
  "title" => String.t(),
  "configured" => true
}
```

The iframe must not need the absolute root path.

5. File entry shape:

```elixir
%{
  "path" => "vault-relative/path.md",
  "title" => "path",
  "size" => non_neg_integer(),
  "modified_at" => String.t() | nil
}
```

6. Read result shape:

```elixir
%{
  "root_id" => "notes",
  "path" => "vault-relative/path.md",
  "content" => String.t(),
  "revision" => String.t(),
  "size" => non_neg_integer(),
  "modified_at" => String.t() | nil
}
```

7. Write params:

```elixir
%{
  "root_id" => "notes",
  "path" => "vault-relative/path.md",
  "content" => String.t(),
  optional("base_revision") => String.t()
}
```

If `base_revision` is present and differs from current file revision, return:

```elixir
%{
  "ok" => false,
  "error" => %{
    "code" => "conflict",
    "message" => String.t()
  }
}
```

8. Delete params:

```elixir
%{
  "root_id" => "notes",
  "path" => "vault-relative/path.md",
  optional("base_revision") => String.t()
}
```

Delete uses the same path boundary and optional revision conflict check as write.

9. Search result shape:

```elixir
%{
  "query" => String.t(),
  "results" => [
    %{
      "path" => String.t(),
      "title" => String.t(),
      "snippet" => String.t()
    }
  ]
}
```

10. ControlPlane tags:

```text
workbench.notes.roots.listed
workbench.notes.files.listed
workbench.notes.file.read
workbench.notes.file.written
workbench.notes.file.deleted
workbench.notes.search.completed
workbench.notes.call.failed
```

## 执行顺序 / stage 依赖

- Stage 1: Config contract。
- Stage 2: Notes backend service and bridge methods。
- Stage 3: Backend tests。
- Stage 4: ProseMark notes app artifact。
- Stage 5: Validation and docs update。

Stage 2 依赖 Stage 1。
Stage 3 依赖 Stage 2。
Stage 4 依赖 Stage 2。
Stage 5 依赖 Stage 3、Stage 4。

## Stage 1

### 前置检查

- `Config.workbench_runtime/1` 当前只返回 enabled/host/port。
- Runtime snapshot 已把 `workbench.runtime` 投影给 server。

### 这一步改哪里

- `lib/nex/agent/config.ex`
- `test/nex/agent/config_test.exs`
- `test/nex/agent/runtime_test.exs`

### 这一步要做

- 让 `normalize_workbench/1` 保留 normalized `"apps"` map。
- 增加 `Config.workbench_app_config/2`。
- 对 `gateway.workbench.apps.notes.root` 做 trim + `Path.expand/1` normalization。

### 实施注意事项

- 不读取或写入真实 `~/.nex/agent/config.json`。
- 不把 notes root 放进 `tools.file_access.allowed_roots`。
- 不让 notes root 扩大通用 file tools 权限。

### 本 stage 验收

- `Config.workbench_runtime/1` 返回 `"apps" => %{"notes" => %{"root" => expanded_root}}`。
- 缺省时 `"apps" => %{}`。
- Runtime snapshot hash 包含 workbench app config 变化。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/config_test.exs test/nex/agent/runtime_test.exs
```

## Stage 2

### 前置检查

- Stage 1 tests pass。
- Bridge method allowlist 仍然集中在 `Nex.Agent.Interface.Workbench.Bridge`。

### 这一步改哪里

- 新增 `lib/nex/agent/workbench/notes.ex`
- `lib/nex/agent/workbench/bridge.ex`
- `lib/nex/agent/workbench/shell.ex`

### 这一步要做

- 实现 notes root resolve。
- 实现 list/read/write/search。
- 在 injected SDK bootstrap 增加 `window.Nex.notes.*` helpers。
- 所有 bridge method 仍走 `Permissions.check/3`。

### 实施注意事项

- 不在 `Router` 内写 notes 业务逻辑。
- 不暴露 arbitrary path / arbitrary file API。
- 不返回 absolute root path 给 iframe。
- 写入用 temp file + rename。

### 本 stage 验收

- 未声明或未授权 notes permission 时拒绝。
- 已授权后可以 list/read/write/search。
- path escape 和 conflict 返回 bounded error。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/workbench/notes_test.exs test/nex/agent/workbench/bridge_test.exs test/nex/agent/workbench/server_test.exs
```

## Stage 3

### 前置检查

- Stage 2 API 已完成。

### 这一步改哪里

- 新增 `test/nex/agent/workbench/notes_test.exs`
- `test/nex/agent/workbench/bridge_test.exs`
- `test/nex/agent/workbench/server_test.exs`

### 这一步要做

- 覆盖 roots/list/read/write/search 主路径。
- 覆盖 permission denied。
- 覆盖 root missing、path escape、non-Markdown write、conflict。
- 覆盖 ControlPlane observations。

### 实施注意事项

- 测试使用临时 workspace 和临时 notes root。
- 不依赖本机真实 Notes 目录。

### 本 stage 验收

- 关键 contract 测试通过。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/workbench/notes_test.exs test/nex/agent/workbench/bridge_test.exs test/nex/agent/workbench/server_test.exs
```

## Stage 4

### 前置检查

- Stage 2 bridge API 可用。
- App artifact 仍放 workspace，不放 core system view。

### 这一步改哪里

- `<workspace>/workbench/apps/notes/nex.app.json`
- `<workspace>/workbench/apps/notes/package.json`
- `<workspace>/workbench/apps/notes/reload.sh`
- `<workspace>/workbench/apps/notes/src/**`
- `<workspace>/workbench/apps/notes/dist/**`

### 这一步要做

- 使用 React + TypeScript + Vite。
- 使用 CodeMirror 6 + ProseMark。
- 单栏 live Markdown editor，不做双栏 preview。
- UI 支持 root list、file list/search、open、edit、save、conflict state。

### 实施注意事项

- `reload.sh` 只 materialize 当前 app artifacts。
- iframe app 不直接访问 backend HTTP API。
- iframe app 不传 absolute path。

### 本 stage 验收

- Workbench 能打开 notes app iframe。
- 授权 `notes:read` / `notes:write` 后可以打开、编辑、保存 Markdown。
- 未配置 root 时 app 显示可操作错误。

### 本 stage 验证

```bash
cd <workspace>/workbench/apps/notes && ./reload.sh
```

## Stage 5

### 前置检查

- Backend tests pass。
- Notes app builds。

### 这一步改哪里

- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/2026-04-28.md`
- `docs/dev/designs/2026-04-28-workbench-app-authoring-guide.md`

### 这一步要做

- 记录 Phase 18D 的当前 contract 和验证命令。
- 记录 ProseMark 第一版决策。
- 记录 notes root config shape。

### 本 stage 验收

- 后续执行者能按 docs 继续开发 notes app。

## Review Fail 条件

- Notes root 被放进 `tools.file_access.allowed_roots` 作为唯一配置方式。
- 第一版 notes UI 做成双栏 preview 而不是 ProseMark editor。
- iframe 可以传 absolute path。
- bridge 暴露 arbitrary filesystem/tool/http capability。
- 写入没有 conflict detection。
- notes app 被实现成 core system view。
- permission denied / path escape / conflict 没有测试。
