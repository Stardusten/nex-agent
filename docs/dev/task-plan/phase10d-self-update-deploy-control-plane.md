# Phase 10d Self-Update Deploy Control Plane

## 当前状态

Phase 10a/10b 补上了 `reflect introspect` 和 `CodeUpgrade` 两块基础能力，但当前自我迭代的控制面仍然是错的：

- `edit/write` 对所有 `.ex` 文件无差别 auto hot reload，把“编辑”和“部署”耦合在一起。
- `upgrade_code` 要求一次提交完整模块源码，长文件被截断后 agent 无法稳定使用。
- `UpgradeManager` + `CodeUpgrade.upgrade_module/3` + `HotReload` 三层嵌套，各自维护 backup/version/rollback 语义，互相不知道对方状态。
- `UpgradeManager` 绑定了单模块 + git commit 语义，和多文件批量 deploy 不兼容。
- `CodeUpgrade` 的 backup/version 存储在 `~/.nex/agent/code_upgrades/`（安全禁区），version 记录包含完整源码。
- `Admin` / `console` / `reflect versions` 仍依赖旧 version store 和旧 upgrade API，代码面没有收口到单一 deploy 控制链。

10d 的目标不是给旧链路再包一层，而是删掉 `upgrade_code` / `UpgradeManager` 这条半完成控制面，重建一条干净的 `edit -> deploy -> release -> rollback` 主链。

## 完成后必须达到的结果

1. `edit/write` 改任何文件都只写磁盘，不触发 runtime 副作用。所有 `.ex` auto hot reload 行为删除。
2. `self_update deploy` 成为唯一的 CODE 层 runtime activation 入口：识别待部署文件 -> 语法检查 -> snapshot -> compile/reload -> 相关测试 -> 记录 release；任一步失败都显式返回，并尽最大努力恢复文件与 runtime。
3. `self_update rollback` 能回到上一个或指定 release，并复用同一条 release store / snapshot 控制链。
4. `self_update status/history` 让 agent 能理解 pending CODE changes、当前 release、可回滚目标和最近 deploy 结果。
5. `upgrade_code` tool 删除，`UpgradeManager` 模块删除，不保留兼容垫片。
6. `CodeUpgrade` 瘦身为纯工具函数集：source path 解析、module 检测、protected 判定、test path 映射、repo root 解析；删除 `upgrade_module/3`、backup、version store 等 orchestration。
7. `Admin` / `console` / `reflect` 依赖旧 API 的代码迁移到新 release store / self_update 接口，或明确删除对应 UI/接口。
8. Release 记录和 snapshot 存储在 repo 内，不依赖安全禁区。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/task-plan/phase10-self-iteration-foundation.md`
- `lib/nex/agent/tool/edit.ex`
- `lib/nex/agent/tool/write.ex`
- `lib/nex/agent/tool/upgrade_code.ex`（将删除）
- `lib/nex/agent/code_upgrade.ex`（将大幅瘦身）
- `lib/nex/agent/hot_reload.ex`
- `lib/nex/agent/upgrade_manager.ex`（将删除）
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/admin.ex`
- `lib/nex/agent/heartbeat.ex`
- `lib/nex/agent/worker_supervisor.ex`
- `lib/nex/agent/tool/reflect.ex`
- `console/src/pages/code.ex`
- `console/src/api/admin/panels/code.ex`
- `test/nex/agent/self_modify_pipeline_test.exs`
- `test/nex/agent/upgrade_manager_test.exs`（将删除）
- `test/nex/agent/admin_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. `read` / `edit` / `write` 参数形状不变。

```elixir
read:  %{"path" => path, "offset" => optional_integer, "limit" => optional_integer}
edit:  %{"path" => path, "search" => search, "replace" => replace}
write: %{"path" => path, "content" => content}
```

2. `edit` / `write` 不再对任何 `.ex` 文件 auto hot reload。

```text
edit/write .ex file -> file changed on disk, period
edit/write non-.ex file -> file changed on disk, period
```

不区分 CODE 层和非 CODE 层。所有编辑行为统一为“只写磁盘”。Hot reload 完全由 `self_update deploy` 或用户手动 `recompile` 触发。

3. CODE 层文件判定唯一真相源放在 `Nex.Agent.Self.CodeUpgrade.code_layer_file?/1`，只覆盖 repo 内 framework code。

```elixir
@spec code_layer_file?(String.t()) :: boolean()
def code_layer_file?(path) do
  expanded = Path.expand(path)
  repo_root = repo_root()
  lib_root = Path.join(repo_root, "lib/nex/agent") |> Path.expand()

  String.ends_with?(expanded, ".ex") and
    String.starts_with?(expanded, lib_root <> "/")
end
```

`test/` 不是 CODE 层。workspace custom tool 不属于本 phase deploy 面，不通过 `self_update deploy` 激活。

4. Protected modules 唯一真相源放在 `Nex.Agent.Self.CodeUpgrade.protected_module?/1`，必须覆盖新的 self_update 控制链。

```elixir
@protected_modules [
  Nex.Agent.Sandbox.Security,
  Nex.Agent.Self.CodeUpgrade,
  Nex.Agent.Self.HotReload,
  Nex.Agent.Capability.Tool.Registry,
  Nex.Agent.Capability.Tool.Core.SelfUpdate,
  Nex.Agent.Self.Update.Planner,
  Nex.Agent.Self.Update.Deployer,
  Nex.Agent.Self.Update.ReleaseStore
]

@spec protected_module?(atom()) :: boolean()
def protected_module?(module), do: module in @protected_modules
```

`UpgradeManager` 和 `Tool.UpgradeCode` 从列表中移除，因为它们会被删掉。

5. 新 tool `self_update`。

```elixir
def name, do: "self_update"
def category, do: :evolution

@type action :: "status" | "deploy" | "rollback" | "history"
```

Surface 归属冻结为：
- `:all` -> 包含
- `:base` / `:subagent` / `:cron` / `:follow_up` -> 不包含

6. `self_update deploy` 参数：

```elixir
%{
  "action" => "deploy",
  "reason" => String.t(),
  optional("files") => [String.t()]
}
```

`files` 传入时，只接受 CODE 层文件。`files` 未传时，默认通过 `git status --porcelain -- lib/nex/agent` 检测 pending CODE 层文件；如果当前 repo 不可用或命令失败，必须返回 warning/错误，不偷偷切换成另一套隐式扫描逻辑。

7. `self_update status` 返回：

```elixir
%{
  status: :ok,
  current_release: String.t() | nil,
  pending_files: [String.t()],
  modules: [String.t()],
  related_tests: [String.t()],
  deployable: boolean(),
  warnings: [String.t()]
}
```

8. `self_update deploy` 成功返回：

```elixir
%{
  status: :deployed,
  release_id: String.t(),
  parent_release_id: String.t() | nil,
  reason: String.t(),
  files: [String.t()],
  modules: [String.t()],
  tests: [%{path: String.t(), status: :passed | :none}],
  rollback_available: true
}
```

9. `self_update deploy` 失败返回：

```elixir
%{
  status: :failed,
  phase: :plan | :syntax | :compile | :tests,
  rolled_back: boolean(),
  restored_files: [String.t()],
  runtime_restored: :none | :best_effort,
  error: String.t(),
  warnings: [String.t()]
}
```

这里不冻结“runtime fully restored”语义。`runtime_restored` 只能表达当前实现是否做了 best-effort reload 恢复，不能假装提供事务式 runtime 回滚。

10. `self_update rollback` 参数：

```elixir
%{
  "action" => "rollback",
  optional("target") => "previous" | String.t()
}
```

未传 `target` 时等价于 `"previous"`。Rollback 后测试失败不做二次 rollback，只返回 warning 和 failure。

11. Release 存储：

```text
<repo_root>/.nex_self_update/releases/<release_id>.json
<repo_root>/.nex_self_update/snapshots/<release_id>/<relative_path>
```

`.nex_self_update/` 加入 `.gitignore`。Release JSON 不存完整源码，只存 metadata。Snapshot 存 deploy 前文件内容，用于 rollback。

```elixir
%{
  id: String.t(),
  parent_release_id: String.t() | nil,
  timestamp: String.t(),
  reason: String.t(),
  files: [%{path: String.t(), before_sha: String.t(), after_sha: String.t()}],
  modules: [String.t()],
  tests: [%{path: String.t(), status: String.t()}],
  status: "deployed" | "rolled_back"
}
```

12. Deploy 流程冻结为：

```text
1. plan: 识别 files -> modules -> tests -> protected check
2. syntax check: Code.string_to_quoted 全部文件（快速失败，不加载）
3. snapshot: 存 deploy 前文件内容
4. compile + reload: 逐文件 HotReload.reload_expected/3
   - 中间失败 -> 恢复已写文件，best-effort 重新 reload 受影响模块
5. test: 跑相关测试
   - 失败 -> 同上恢复
6. save release
```

不走 `UpgradeManager`，不走 `CodeUpgrade.upgrade_module/3`。直接调 `HotReload` 的底层编译/加载能力，但不把它包装成“原子事务 deploy”。

13. 删除清单：

| 删除 | 原因 |
|------|------|
| `lib/nex/agent/upgrade_manager.ex` | 整个模块删除 |
| `lib/nex/agent/tool/upgrade_code.ex` | 整个模块删除 |
| `test/nex/agent/upgrade_manager_test.exs` | 跟随删除 |
| `lib/nex/agent/tool/tool_upgrade_target.ex` | 测试残留，清理 |
| `CodeUpgrade.upgrade_module/3` | 删除 orchestration |
| `CodeUpgrade.rollback/1,2` | 删除，由 self_update deployer 接管 |
| `CodeUpgrade.create_backup/2`, `backup_path/1`, `restore_backup/2` | 删除 |
| `CodeUpgrade.save_version/2`, `list_versions/1`, `get_version/2`, `current_version/1` | 删除旧 version store |
| `CodeUpgrade.versions_root/0` | 删除 |
| `CodeUpgrade.diff/2` | 删除 |

14. `CodeUpgrade` 瘦身后保留的公共 API：

```elixir
defmodule Nex.Agent.Self.CodeUpgrade do
  @spec source_path(atom()) :: String.t()
  @spec can_upgrade?(atom()) :: boolean()
  @spec list_upgradable_modules() :: [atom()]
  @spec get_source(atom()) :: {:ok, String.t()} | {:error, String.t()}
  @spec code_layer_file?(String.t()) :: boolean()
  @spec protected_module?(atom()) :: boolean()
  @spec related_test_path(String.t()) :: {:ok, String.t(), String.t()} | :none
  @spec repo_root() :: String.t()
end
```

纯函数 / 工具函数集合，不保留 orchestration 状态。允许 `get_source/1` 读文件，其余不做 deploy side effect。

15. 受影响调用点迁移方案冻结为：

| 调用点 | 迁移 |
|--------|------|
| `worker_supervisor.ex` UpgradeManager child | 删除该 child |
| `admin.ex` `hot_upgrade_code/4` | 删除；admin 改为委托 self_update deploy API 或只读 |
| `admin.ex` `rollback_code/3` | 删除；admin 改为委托 self_update rollback API 或只读 |
| `admin.ex` `list_versions` / `code_state.versions` | 改为读 `SelfUpdate.ReleaseStore` |
| `heartbeat.ex` `run_code_upgrade_cleanup` | 改为清理 `.nex_self_update/` 或删除 |
| `registry.ex` `@default_tools` | 删 `UpgradeCode`，加 `SelfUpdate` |
| `tool_list.ex` `"upgrade_code"` category | 删除该条目；新增 `self_update` |
| `reflect.ex` `versions` action | 改为读 release store，或删除该 action |
| `console/src/pages/code.ex` | 不再直接调用旧 hot upgrade/rollback API；要么走新 API，要么降为只读 |
| `onboarding.ex` 文档引用 | 更新文案 |

16. `Admin` / `console` contract 在本 phase 内必须二选一明确收口：

- 要么保留 code panel 的 deploy/rollback 操作，但统一委托 `SelfUpdate` 控制面。
- 要么把 code panel 降成只读预览，彻底删除旧 hot upgrade/rollback 操作入口。

不允许保留旧 API 名字但内部偷偷兼容旧 orchestration。

## 执行顺序 / stage 依赖

- Stage 1：删旧控制面，瘦身 `CodeUpgrade`，让仓库重新回到单一待实现状态。
- Stage 2：去掉 `edit/write` auto reload，把“写文件”和“部署”彻底解耦。
- Stage 3：实现 `SelfUpdate` 主链、release store 和新 tool。
- Stage 4：迁移 `Admin` / `console` / `reflect` / 文档 / 测试，收口所有外部入口。

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1、Stage 2。  
Stage 4 依赖 Stage 3。  

## Stage 1

### 前置检查

- 通读 `CodeUpgrade`、`UpgradeManager`、`HotReload` 的职责边界，确认当前 backup/version/rollback 语义分散。
- 确认 `Admin` / `console` 依赖旧 API 的调用点列表完整。
- 确认 `self_modify_pipeline_test` 里有哪些断言绑定旧 API 和旧 version store。

### 这一步改哪里

- `lib/nex/agent/code_upgrade.ex`
- 删除 `lib/nex/agent/upgrade_manager.ex`
- 删除 `lib/nex/agent/tool/upgrade_code.ex`
- `lib/nex/agent/worker_supervisor.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/admin.ex`
- `test/nex/agent/self_modify_pipeline_test.exs`
- 删除 `test/nex/agent/upgrade_manager_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

### 这一步要做

- 删掉 `UpgradeManager` child 和 `upgrade_code` tool 注册。
- 从 `CodeUpgrade` 删除：
  - `upgrade_module/3`
  - `rollback/1,2`
  - backup/version store 相关函数
  - `diff/2`
- 保留并整理 `CodeUpgrade` 的纯工具 API：
  - `source_path/1`
  - `can_upgrade?/1`
  - `list_upgradable_modules/0`
  - `get_source/1`
  - `code_layer_file?/1`
  - `protected_module?/1`
  - `related_test_path/1`
  - `repo_root/0`
- 更新测试，使仓库先在“旧控制面已删除，新控制面未实现”的状态下仍有清晰编译错误或 TODO 缺口，而不是靠兼容垫片苟住。

### 实施注意事项

- 不保留 `UpgradeManager` 空壳模块。
- 不保留 `upgrade_code` 到 `self_update` 的别名/转发兼容层。
- `CodeUpgrade` 的 `protected_module?` 必须直接覆盖新的 self_update 控制链目标模块，避免后续实现时忘记保护面。

### 本 stage 验收

- `UpgradeManager` 和 `upgrade_code` 已从 runtime/tool surface 删除。
- `CodeUpgrade` 不再承担 deploy/rollback orchestration。
- 编译错误只剩 self_update 新链路待补的调用点，不残留旧 API 的平行入口。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix compile`
- `mix test test/nex/agent/tool_alignment_test.exs`

## Stage 2

### 前置检查

- Stage 1 已完成，旧 deploy 控制面已删除。
- 当前 `edit` / `write` 仍然在 `.ex` 路径上调用 `HotReload`。

### 这一步改哪里

- `lib/nex/agent/tool/edit.ex`
- `lib/nex/agent/tool/write.ex`
- `test/nex/agent/write_edit_tool_test.exs`
- `test/nex/agent/code_layer_boundary_test.exs`

### 这一步要做

- 删除 `edit` / `write` 对 `HotReload` 的直接依赖。
- 更新 tool description，明确它们只负责磁盘写入，不负责 hot reload。
- 保留现有 path validation 与 reserved profile guard。
- 为 `.ex` 文件写入增加回归测试，确认写盘成功但不触发 runtime side effect。

### 实施注意事项

- 不要只对 CODE 层关闭 auto reload；所有 `.ex` 都要统一变成纯写盘。
- 不要顺手改 custom tool 运行时加载策略；那是 TOOL 层，不是本 phase 的 deploy contract。

### 本 stage 验收

- `edit` / `write` 改 `.ex` 文件只改磁盘，不再返回 hot reload payload。
- `.ex` 写入失败时仍保留明确错误语义。
- 现有 tool surface/参数形状不变。

### 本 stage 验证

- `mix test test/nex/agent/write_edit_tool_test.exs`
- `mix test test/nex/agent/code_layer_boundary_test.exs`

## Stage 3

### 前置检查

- Stage 1、Stage 2 已完成。
- `CodeUpgrade` 已经只剩工具函数，可作为 planner/deployer 的唯一辅助真相源。
- 确认 `HotReload.reload_expected/3` 只能提供逐文件 compile/load，不能假装成事务式 deploy。

### 这一步改哪里

- 新增 `lib/nex/agent/self_update/planner.ex`
- 新增 `lib/nex/agent/self_update/deployer.ex`
- 新增 `lib/nex/agent/self_update/release_store.ex`
- 新增 `lib/nex/agent/tool/self_update.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/admin.ex`
- `lib/nex/agent/heartbeat.ex`
- `test/nex/agent/self_modify_pipeline_test.exs`
- 新增 `test/nex/agent/self_update_test.exs`

### 这一步要做

- 新建 `SelfUpdate.Planner`：
  - 校验 `files`
  - 识别 modules
  - 识别 related tests
  - 拒绝 protected modules
  - 在默认模式下通过 `git status --porcelain -- lib/nex/agent` 收集 pending files
- 新建 `SelfUpdate.ReleaseStore`：
  - 管理 `.nex_self_update/releases`
  - 管理 `.nex_self_update/snapshots`
  - 提供 `current_release/0`、`list_releases/0`、`save_release/1`、`load_release/1`
- 新建 `SelfUpdate.Deployer`：
  - 按冻结的 deploy 主链执行
  - syntax check
  - snapshot
  - 逐文件 `HotReload.reload_expected/3`
  - 相关测试
  - 失败时恢复文件内容，并对受影响模块做 best-effort reload 恢复
- 新建 `Tool.SelfUpdate`：
  - 支持 `status` / `deploy` / `rollback` / `history`
  - 返回冻结 shape
- `Heartbeat` 的旧 code upgrade cleanup 改为 release store cleanup 或直接删除。
- `Admin` 增加读 release store 的接口，供 Stage 4 迁移使用。

### 实施注意事项

- 不要把 planner/deployer/release store 的状态缓存进长期 GenServer；优先做纯函数/短生命周期 orchestrator。
- `runtime_restored` 只能表达 best-effort，不允许在返回里声称原子回滚成功。
- `status` 默认 pending 检测依赖 git；测试里必须显式覆盖 git 不可用/非 git repo 的返回，不要默默回退成 `File.ls`.
- `.nex_self_update/` 必须接入 repo root，而不是另起一套 HOME 路径。

### 本 stage 验收

- `self_update` 出现在 `:all` tool surface，且不出现在 `:base` / `:subagent` / `:cron` / `:follow_up`。
- `self_update status` 能返回当前 release、pending files、modules、related tests。
- `self_update deploy` 成功时写 release metadata 与 snapshots。
- `self_update deploy` 失败时能恢复磁盘文件，并返回 `runtime_restored: :best_effort | :none`。
- `self_update rollback` 能使用 snapshot 恢复上一个或指定 release。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix compile`
- `mix test test/nex/agent/self_update_test.exs`
- `mix test test/nex/agent/self_modify_pipeline_test.exs`

## Stage 4

### 前置检查

- Stage 3 已完成，`SelfUpdate` 主链可用。
- `Admin` / `console` / `reflect` 仍至少有一处直接依赖旧 API 或旧 versions 语义。

### 这一步改哪里

- `lib/nex/agent/admin.ex`
- `lib/nex/agent/tool/reflect.ex`
- `console/src/pages/code.ex`
- `console/src/api/admin/panels/code.ex`
- `test/nex/agent/admin_test.exs`
- `test/nex/agent/tool_alignment_test.exs`
- `docs/dev/task-plan/index.md`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/2026-04-24.md`

### 这一步要做

- `Admin` 删除旧 `hot_upgrade_code/4`、`rollback_code/3` 语义，统一切到新 self_update API，或把对应入口改成只读。
- `reflect`：
  - `versions` action 改为读 release store，或直接删除
  - 不再引用 `CodeUpgrade.list_versions/1`
- `console`：
  - 二选一收口
  - 若保留 deploy/rollback 操作，调用新 API，且文案反映 release/deploy 模型
  - 若降只读，删除 hot upgrade / rollback 表单和事件
- 同步 `tool_alignment_test`、`admin_test` 和 phase/index/progress 文档。

### 实施注意事项

- 不允许保留旧 API 名字再偷偷转发到新实现。
- 不允许 console 继续显示“version history”但底层已变成 release history 而不改文案。
- 文档里要明确 phase10d 已经把 deploy 控制面改成 release/release-store 模型。

### 本 stage 验收

- 仓库内没有 `upgrade_code` 旧入口残留。
- `Admin` / `console` / `reflect` / 测试 / 文档 对齐同一份 release contract。
- reviewer 能通过 code panel 或 admin state 看见新 release history，而不是旧 module versions。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix compile`
- `mix test test/nex/agent/admin_test.exs`
- `mix test test/nex/agent/tool_alignment_test.exs`
- `mix test test/nex/agent/self_modify_pipeline_test.exs`

## Review Fail 条件

- `edit` / `write` 仍对任意 `.ex` 文件触发 hot reload。
- `upgrade_code`、`UpgradeManager`、旧 version store 仍以兼容层形式保留在主链。
- `self_update` 之外仍存在第二条 CODE deploy/rollback orchestration。
- 新的 self_update planner/deployer/release store 没有进入 protected modules 真相源。
- 实现或文档把 `HotReload` 的逐文件 compile/load 伪装成事务式 runtime rollback。
- `Admin` / `console` / `reflect` / 测试 / 文档 对 release contract 不一致。
- `.nex_self_update` 没有落在 repo root，或者仍把源码版本存到安全禁区。
- 只补 happy path，没有覆盖 deploy 失败和 rollback 主中断路径。
