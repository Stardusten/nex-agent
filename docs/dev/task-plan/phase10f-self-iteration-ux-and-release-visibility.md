# Phase 10f Self-Iteration UX And Release Visibility

## 当前状态

Phase 10d 已经把 CODE deploy 控制面收口到 `self_update`，Phase 10e 也已经把查看/编辑工具面重置成 `find -> read -> apply_patch -> self_update` 主链。旧的 `upgrade_code` / `UpgradeManager` / `edit` / `write` / `list_dir` 主路径已经退出主链。

但从 agent 真正执行一次“发现问题 -> 看代码 -> 改代码 -> 预检 -> deploy/rollback -> 理解 release 状态”的角度，链路仍不够顺：

- 10e 虽然解决了 `read` 的结构化分页和 `reflect list_modules` 暴露 protected module 的问题，但 inspect 链路仍然分成 path-first 和 module-first 两套心智，agent 还得自己判断什么时候走 `read`、什么时候走 `reflect`.
- `self_update status` 还是偏薄：能告诉你能不能 deploy，但不告诉你 blocked reasons 的结构化细节、默认 plan 是怎么来的、哪些 release 是当前可达 rollback target。
- `reflect versions` 和 `self_update history/status` 仍然是平行只读面；当前 effective release、`previous` 的真实含义、rollback candidates 还没有在同一条控制链上结构化暴露。
- prompt / onboarding 还没有把“quick preflight” 和 “strict ship verification” 讲清楚。当前 agent 既可能把 `self_update deploy` 当成最终完整验收，也可能被 prompt 里的 `format/credo/dialyzer` 吓得过度保守。
- 如果未来要走“主 agent 让 subagent 改代码，然后 owner run 决定是否 deploy”，当前缺少显式 handoff model，agent 仍需要自己脑补“谁改、谁 deploy、谁负责最终验证”。
- `self_update deploy` 跑 related tests 仍是逐个 `mix test` 串行，对 agent 快速试错偏慢。

10f 的目标不是再重做工具，也不是再新增一条 orchestration，而是把 **inspect / preflight / release visibility / verification policy / owner handoff** 补成一条 agent 真能顺滑使用的主链。

## 完成后必须达到的结果

1. agent 无论从 module 名还是文件路径起手，都能走到同一套结构化 inspect 结果，不再依赖人脑补两套工作流差异。
2. `self_update status` 成为唯一的 deploy preflight 入口：显式说明 plan source、deployable、blocked reasons、相关 tests、current effective release、`previous` rollback target 和 rollback candidates。
3. `self_update history` / `reflect versions` / release store 对齐到同一份 release visibility contract，不再让 agent 自己推 release lineage。
4. prompt / onboarding 明确区分：
   - quick preflight / deploy verification
   - strict ship checks
   agent 不再在“deploy 成功是不是就算完全验收”上摇摆。
5. owner/subagent handoff 规则明确：
   - subagent 可 `find/read/reflect/apply_patch`
   - owner run 负责 `self_update status/deploy/rollback`
   不新增第二条 deploy 控制面。
6. related tests 执行路径收口并提速；至少不再逐文件串行 `mix test`.
7. 所有新增状态、候选列表、effective release 推导都来自统一真相源，不新增第二套 release world view。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/task-plan/phase10d-self-update-deploy-control-plane.md`
- `docs/dev/task-plan/phase10e-code-editing-toolchain-reset.md`
- `lib/nex/agent/tool/read.ex`
- `lib/nex/agent/tool/reflect.ex`
- `lib/nex/agent/tool/self_update.ex`
- `lib/nex/agent/self_update/deployer.ex`
- `lib/nex/agent/self_update/planner.ex`
- `lib/nex/agent/self_update/release_store.ex`
- `lib/nex/agent/code_upgrade.ex`
- `lib/nex/agent/onboarding.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/follow_up.ex`
- `lib/nex/agent/tool/registry.ex`
- `test/nex/agent/read_tool_test.exs`
- `test/nex/agent/find_tool_test.exs`
- `test/nex/agent/self_update_test.exs`
- `test/nex/agent/self_update_planner_test.exs`
- `test/nex/agent/self_update_release_store_test.exs`
- `test/nex/agent/self_modify_pipeline_test.exs`
- `test/nex/agent/code_layer_boundary_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. 10e 工具主链继续冻结为：

```text
find -> read/reflect -> apply_patch -> self_update status/deploy
```

10f 不新增新的编辑 tool，不恢复旧 `edit` / `write`.

2. `reflect source` 升级为统一 inspect 入口，支持 module-first 与 path-first，两者返回同一 shape。

输入冻结为：

```elixir
%{
  "action" => "source",
  optional("module") => String.t(),
  optional("path") => String.t()
}
```

要求：
- `module` 和 `path` 必须二选一，不能同时缺失，也不能同时传。
- `path` 仅允许 repo 内 framework CODE path。

返回冻结为结构化 map，不再返回 markdown 字符串：

```elixir
%{
  status: :ok,
  module: String.t(),
  path: String.t(),
  content: String.t(),
  source_kind: :module | :path
}
```

3. `reflect list_modules` 返回结构化 discovery，而不是人读字符串列表。

```elixir
%{
  status: :ok,
  modules: [
    %{
      module: String.t(),
      path: String.t(),
      deployable: boolean(),
      protected: boolean()
    }
  ]
}
```

`deployable` / `protected` 必须直接基于 `CodeUpgrade.protected_module?/1` 和 CODE-layer 边界，不允许再让 agent 通过失败结果反推。

4. `self_update status` 返回 shape 升级并冻结为：

```elixir
%{
  status: :ok,
  plan_source: :explicit | :pending_git,
  current_effective_release: String.t() | nil,
  current_event_release: String.t() | nil,
  previous_rollback_target: String.t() | nil,
  pending_files: [String.t()],
  modules: [String.t()],
  related_tests: [String.t()],
  rollback_candidates: [String.t()],
  deployable: boolean(),
  blocked_reasons: [String.t()],
  warnings: [String.t()]
}
```

要求：
- `deployable == false` 时，主原因必须进 `blocked_reasons`，不是只塞进 `warnings`.
- `plan_source` 必须告诉 agent 当前 plan 来自显式 files 还是默认 pending git 检测。
- `current_effective_release` 与 `current_event_release` 必须显式区分；多次 rollback 后 agent 不需要自己推 lineage。

5. `self_update history` 返回 shape 冻结为：

```elixir
%{
  status: :ok,
  current_effective_release: String.t() | nil,
  releases: [
    %{
      id: String.t(),
      status: String.t(),
      reason: String.t(),
      timestamp: String.t(),
      parent_release_id: String.t() | nil,
      effective: boolean(),
      rollback_candidate: boolean()
    }
  ]
}
```

`reflect versions` 必须复用这同一条 release visibility 真相源，不再自己拼一套文本历史。

6. verification policy 冻结为两档：

```text
deploy quick-check:
- self_update deploy runs syntax/compile/reload/related tests

ship strict-check:
- optional explicit extra checks such as format/credo/dialyzer, triggered by user intent or explicit ship flow
```

prompt / onboarding / tool descriptions 必须对齐这两档，不允许混成一句“改代码后都跑完整重检查”。

7. owner/subagent handoff 冻结为：

```text
subagent:
- may inspect and patch code
- may not deploy or rollback

owner run:
- owns self_update status/deploy/rollback
- owns final verification decision
```

10f 不改变 `self_update` surface；只把这个 handoff model 讲清楚并接到统一 prompt / execution contract。

8. related tests 执行收口冻结为：

```text
one deploy -> one test invocation plan
```

允许实现为：
- 单次 `mix test file1 file2 ...`
- 或其他等价单计划执行方式

但不允许继续“每个 test file 单独起一个 `mix test` 串行跑”的主实现。

## 执行顺序 / stage 依赖

- Stage 1：统一 inspect / discovery contract，让 agent 不再在 path-first 与 module-first 之间摇摆。
- Stage 2：统一 preflight / history / rollback visibility contract，让 agent 不再自己推 release state。
- Stage 3：对齐 prompt / handoff / verification policy。
- Stage 4：收口 related tests 执行计划并提速。

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 2。  
Stage 4 依赖 Stage 2。  

## Stage 1

### 前置检查

- 确认当前 `reflect source` 仍只能 module-first。
- 确认 `read` 已能稳定分页，但 agent 仍需自己决定何时切到 `reflect`.
- 确认 `reflect list_modules` 已过滤 protected modules，但还不是结构化 discovery。

### 这一步改哪里

- `lib/nex/agent/tool/reflect.ex`
- `lib/nex/agent/code_upgrade.ex`
- `test/nex/agent/code_layer_boundary_test.exs`
- 新增 `test/nex/agent/reflect_tool_test.exs`

### 这一步要做

- `reflect source` 支持 `path`.
- 把 `reflect source` / `list_modules` 改成结构化返回。
- 对 module-first 和 path-first 输出统一 shape。
- `list_modules` 返回 path / deployable / protected.

### 实施注意事项

- 不要新建第二个平行 tool，如 `inspect_path` 或 `module_source`.
- path-first 的 CODE-layer 判定必须继续复用 `CodeUpgrade.code_layer_file?/1`.
- 不要让 `reflect` 越界到 workspace custom tool 编辑面。

### 本 stage 验收

- agent 可从模块名或路径起手，拿到同一类 inspect 结果。
- `reflect list_modules` 直接告诉 agent 哪些模块可 deploy。

### 本 stage 验证

- `mix test test/nex/agent/reflect_tool_test.exs`
- `mix test test/nex/agent/code_layer_boundary_test.exs`

## Stage 2

### 前置检查

- Stage 1 已完成，inspect/discovery 已是结构化返回。
- 当前 `self_update status/history` 仍未把 effective release / rollback candidates / blocked reasons 说清楚。

### 这一步改哪里

- `lib/nex/agent/tool/self_update.ex`
- `lib/nex/agent/tool/reflect.ex`
- `lib/nex/agent/self_update/deployer.ex`
- `lib/nex/agent/self_update/planner.ex`
- `lib/nex/agent/self_update/release_store.ex`
- `test/nex/agent/self_update_test.exs`
- `test/nex/agent/self_update_release_store_test.exs`
- `test/nex/agent/self_modify_pipeline_test.exs`

### 这一步要做

- 新增 `current_effective_release` / `current_event_release`.
- 新增 `previous_rollback_target` / `rollback_candidates`.
- 新增 `plan_source` / `blocked_reasons`.
- `history` 返回结构化 release list，并标记 `effective` / `rollback_candidate`.
- `reflect versions` 改成复用同一 release visibility 真相源。

### 实施注意事项

- effective release 推导必须只基于当前 release store 真相源，不能在 tool 层再各写一套 lineage 推导。
- `blocked_reasons` 和 `warnings` 的语义必须分开。
- 不允许 `reflect versions` 继续维护独立文本格式历史，再由 agent 自己解析。

### 本 stage 验收

- agent 仅用 `self_update status/history` 就能理解当前 release state 和可达 rollback 目标。
- 多次 rollback 后，不需要 agent 自己推断 `previous` 指向哪里。

### 本 stage 验证

- `mix test test/nex/agent/self_update_test.exs`
- `mix test test/nex/agent/self_modify_pipeline_test.exs`
- `mix test test/nex/agent/self_update_release_store_test.exs`

## Stage 3

### 前置检查

- Stage 2 已完成，preflight / history contract 已稳定。
- prompt / onboarding 仍把 quick deploy verification 与 strict ship verification 混在一起。
- subagent/owner handoff 仍主要靠隐含约定。

### 这一步改哪里

- `lib/nex/agent/onboarding.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/follow_up.ex`
- `lib/nex/agent/tool/registry.ex`
- `test/nex/agent/tool_alignment_test.exs`
- `test/nex/agent/context_builder_test.exs`

### 这一步要做

- 明确 quick-check vs strict-check.
- 把“模块名已知优先 `reflect source`，路径已知优先 `read` / `reflect path`”写进 prompt。
- 明确 subagent 改代码、owner deploy 的 handoff model。
- 确认 tool surfaces 仍符合冻结边界，但 prompt 不再让 agent误以为 subagent 能 deploy。

### 实施注意事项

- 不要因为写 prompt 就放宽 `self_update` surface。
- 不要把 strict-check 自动绑进 `self_update deploy`，避免重新让 deploy 变得过重。
- 不要让 follow-up surface 漏出 `apply_patch` / `self_update`.

### 本 stage 验收

- agent 能稳定做出：
  - 先 preflight
  - 再 patch
  - 再 deploy
  - 需要 full ship confidence 时才跑 strict checks
- owner/subagent 分工对 agent 是显式的，不靠暗知识。

### 本 stage 验证

- `mix test test/nex/agent/tool_alignment_test.exs`
- `mix test test/nex/agent/context_builder_test.exs`

## Stage 4

### 前置检查

- Stage 2 已完成，related tests 识别已稳定。
- 当前 deploy 仍逐测试文件串行起 `mix test`.

### 这一步改哪里

- `lib/nex/agent/self_update/deployer.ex`
- `test/nex/agent/self_modify_pipeline_test.exs`
- 新增 `test/nex/agent/self_update_performance_test.exs`

### 这一步要做

- 把 related tests 执行改成单计划收口：
  - 单次 `mix test file1 file2 ...`
  - 或等价单次执行计划
- 返回结构仍要能对应到每个 test path。
- 保持失败语义和 rollback 语义不变。

### 实施注意事项

- 不要为了提速新加第二条验证主链。
- 不要牺牲失败定位可读性。
- timeout / output truncation contract 继续保留。

### 本 stage 验收

- 同一 deploy 的 related tests 不再逐个单独起 `mix test`.
- 结果仍然可映射回每个 test file。

### 本 stage 验证

- `mix test test/nex/agent/self_modify_pipeline_test.exs`
- `mix test test/nex/agent/self_update_performance_test.exs`

## Review Fail 条件

- 又新增一套 path-first / module-first 平行 inspect tool，而不是统一 `reflect`.
- `self_update status/history` 仍让 agent 自己推 effective release / rollback lineage。
- `blocked_reasons` / `warnings` 语义不清，agent 还得靠字符串猜可 deploy 性。
- prompt 仍把 quick deploy verification 和 strict ship verification 混成一条。
- 为了 handoff 清晰度而放宽 `self_update` surface 给 subagent。
- related tests 仍按每个 test file 单独串行起 `mix test`.
