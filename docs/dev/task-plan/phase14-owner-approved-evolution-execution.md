# Phase 14 Owner-Approved Evolution Execution

## 当前状态

Phase 13E 已经把 evolution 收口到 ControlPlane：

- `Evolution.run_evolution_cycle/1` 基于 `ControlPlane.Query/Gauge/Budget` 生成 candidate actions。
- candidate 通过 `evolution.candidate.proposed` observation 持久化，并带 `evidence_ids`。
- `reflect` / `admin` / `observe` 已经可以读到 evolution history、candidate history、budget mode、signal observations。
- 13E 明确禁止自动写 `SOUL/MEMORY/skills/code` 和自动 deploy。

现在缺的不是“再多一个分析阶段”，而是 candidate 的 owner-approved execution 主链：

- candidate 目前只有 proposal，没有统一的批准 / 拒绝 / 执行 / 重试状态机。
- owner 没有一个单一入口来查看 pending candidates、批准它们、或者拒绝它们。
- `memory_candidate` / `skill_candidate` / `soul_candidate` / `code_hint` 都还没有统一落到现有 deterministic execution lane。
- 如果直接在各个地方零散加 “approve memory candidate” / “apply code hint” helper，很容易再长出一套平行 orchestration 和平行状态。

Phase 14 的目标是：在不破坏 13E “candidate-only” 边界的前提下，引入一个最小但完整的 owner-approved execution control lane，让 evolution 从“提出候选动作”变成“能被 owner 审批并沿既有主链执行”。

## 完成后必须达到的结果

1. candidate lifecycle 的机器真相源仍然只有 ControlPlane observations，不新增 `candidates.json`、审批队列表、execution ledger 之类平行状态文件。
2. repo 内只有一个 owner-facing deterministic candidate execution 入口：

```text
evolution_candidate
```

3. `evolution_candidate` 支持最小必要动作：
   - `list`
   - `show`
   - `approve`
   - `reject`
4. `list/show` 返回的是由 `evolution.candidate.*` observations 推导出的 candidate state view，而不是从私有文件读一份状态。
5. `approve` 必须先写 approval observation，再沿既有主链执行；不得在 tool 内自己重写 memory/skill/soul/code 操作逻辑。
6. candidate execution 必须复用已有 deterministic lane：
   - `memory_candidate` -> `memory_write`
   - `soul_candidate` -> `soul_update`
   - `skill_candidate` -> `skill_create` 或现有 skill import/create 主链
   - `code_hint` -> `find/read/apply_patch/self_update` 对应的 CODE lane
7. `code_hint` 的执行仍然受 owner 控制；不得绕过 `self_update` deploy 主链。
8. follow-up / subagent surface 不暴露 `evolution_candidate approve/reject` 这类 owner-only capability。
9. candidate lifecycle observations 完整覆盖：
   - proposed
   - approved
   - rejected
   - realization generated / failed
   - apply started / completed / failed
   - superseded
10. `admin` / `reflect` / `observe` 对同一 candidate id 看到的是同一条 lifecycle，而不是各自维护一份 candidate state。

## 开工前必须先看的代码路径

- `docs/dev/task-plan/phase10d-self-update-deploy-control-plane.md`
- `docs/dev/task-plan/phase10e-code-editing-toolchain-reset.md`
- `docs/dev/task-plan/phase10f-self-iteration-ux-and-release-visibility.md`
- `docs/dev/task-plan/phase13e-evolution-control-plane-consumption.md`
- `lib/nex/agent/evolution.ex`
- `lib/nex/agent/evolution/evidence.ex`
- `lib/nex/agent/control_plane/query.ex`
- `lib/nex/agent/control_plane/log.ex`
- `lib/nex/agent/admin.ex`
- `lib/nex/agent/tool/reflect.ex`
- `lib/nex/agent/tool/tool_list.ex`
- `lib/nex/agent/tool/memory_write.ex`
- `lib/nex/agent/tool/soul_update.ex`
- `lib/nex/agent/tool/skill_create.ex`
- `lib/nex/agent/self_update/deployer.ex`
- `test/nex/agent/evolution_test.exs`
- `test/nex/agent/evolution_integration_test.exs`
- `test/nex/agent/admin_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. Phase 14 不改变 13E candidate shape。

`evolution.candidate.proposed` 仍然是 13E 冻结的最小 shape。Phase 14 只能在其后追加 lifecycle observations，不能把 proposed candidate 改成另一套 struct 或文件格式。

2. candidate lifecycle 只用 observations 表达。

```text
do not add:
- control_plane/state/evolution_candidates.json
- memory/candidates.jsonl
- admin private candidate cache
- session metadata candidate mirrors
```

pending / approved / rejected / applied / failed / superseded 都必须由 observation reduction 推导。

3. Owner-only execution surface 冻结为单 tool：

```text
evolution_candidate
```

不得同时再新增 `candidate_apply`、`approve_candidate`、`reject_candidate`、`evolution_execute` 等平行 tool。

4. `evolution_candidate` public API 冻结为：

```elixir
%{
  "action" => "list" | "show" | "approve" | "reject",
  optional("candidate_id") => String.t(),
  optional("decision_reason") => String.t(),
  optional("mode") => "plan" | "apply"
}
```

规则：

- `list`：列出当前 workspace 的 recent candidates with derived status
- `show`：返回单 candidate 的 full derived lifecycle
- `approve`：owner 批准 candidate；默认 `mode="apply"`
- `reject`：owner 拒绝 candidate

5. candidate derived view shape 冻结为：

```elixir
%{
  "candidate_id" => String.t(),
  "kind" => String.t(),
  "summary" => String.t(),
  "rationale" => String.t(),
  "evidence_ids" => [String.t()],
  "risk" => "low" | "medium" | "high",
  "status" =>
    "pending"
    | "approved"
    | "rejected"
    | "realized"
    | "applied"
    | "failed"
    | "superseded",
  "trigger" => String.t() | nil,
  "profile" => String.t() | nil,
  "budget_mode" => String.t() | nil,
  "proposed_at" => String.t(),
  "decided_at" => String.t() | nil,
  "applied_at" => String.t() | nil,
  "latest_error" => String.t() | nil,
  "lifecycle_observation_ids" => [String.t()]
}
```

6. candidate lifecycle tags 冻结为点分字符串：

```text
evolution.candidate.proposed
evolution.candidate.approved
evolution.candidate.rejected
evolution.candidate.realization.generated
evolution.candidate.realization.failed
evolution.candidate.apply.started
evolution.candidate.apply.completed
evolution.candidate.apply.failed
evolution.candidate.superseded
```

不得新增 underscore form，如 `evolution.candidate_apply_failed`。

7. realization boundary 冻结：

Phase 14 不允许 candidate observation 直接携带 full patch、full skill content、full SOUL/MEMORY body 作为 long-term state。approve path 可以生成一个 bounded realization payload，再调用既有 deterministic lane。

realization payload 最小 shape：

```elixir
%{
  "candidate_id" => String.t(),
  "kind" => String.t(),
  "mode" => "plan" | "apply",
  "summary" => String.t(),
  "execution" => map()
}
```

`execution` 必须是 bounded/redacted，不能变成新的 hidden source-of-truth document store。

8. execution reuse boundary 冻结：

Phase 14 只允许调用既有执行入口，不允许在 candidate tool 内复制实现：

```text
memory candidate -> Nex.Agent.Tool.MemoryWrite.execute/2 or existing memory write entry
soul candidate -> Nex.Agent.Tool.SoulUpdate.execute/2
skill candidate -> Nex.Agent.Tool.SkillCreate.execute/2 or existing skill create/import lane
code hint -> existing CODE lane (find/read/apply_patch/self_update)
```

9. owner boundary 冻结：

```text
owner run:
- may list/show/approve/reject candidates

follow_up:
- may list/show only if explicitly exposed later
- may not approve/reject/apply candidates

subagent:
- may not approve/reject/apply candidates unless user explicitly delegates owner authority in a later phase
```

10. `mode` boundary for code candidates：

为降低 Phase 14 复杂度，`code_hint` 的 `approve` 支持两种模式：

```text
mode=plan:
- generate execution plan / patch proposal observation
- do not deploy

mode=apply:
- run existing CODE lane end-to-end
- still use self_update as deploy authority
```

默认 `approve` 使用 `mode="apply"` for non-code candidates；`code_hint` 若未显式传 `mode`，默认 `plan`。

11. Review/UX boundary：

`admin` / `reflect` / `evolution_status` / `evolution_history` 必须展示 candidate status 和 lifecycle，不再只显示 proposed 事件。

## 执行顺序 / stage 依赖

- Stage 0：preflight，确认 13E 验收通过且 13D logger residual 已收口。
- Stage 1：candidate lifecycle reduction/query layer。
- Stage 2：owner-only `evolution_candidate` tool surface。
- Stage 3：memory/soul/skill candidate realization + apply lanes。
- Stage 4：code_hint plan/apply lane 接入既有 CODE 主链。
- Stage 5：admin/reflect/status 展示 candidate lifecycle。
- Stage 6：prompt/onboarding/progress 收尾。

Stage 1 依赖 Stage 0。  
Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 2。  
Stage 4 依赖 Stage 2、Stage 3。  
Stage 5 依赖 Stage 2、Stage 3、Stage 4。  
Stage 6 依赖 Stage 5。  

## Stage 0

### 前置检查

- Phase 13E focused tests 通过。
- `control_plane_logger_cutover_test.exs` 通过。
- candidate proposals 已经只来自 ControlPlane，不再读 `patterns.jsonl`。

### 这一步改哪里

- `docs/dev/task-plan/phase14-owner-approved-evolution-execution.md`
- `lib/nex/agent/evolution.ex`
- `test/nex/agent/evolution_test.exs`

### 这一步要做

- 确认 13E 的 candidate-only contract 已经稳定。
- 确认 Phase 14 不会重新引入 candidate 平行状态文件。
- 明确 `code_hint` 默认 `approve -> mode=plan` 的安全边界。

### 实施注意事项

- 不在 Stage 0 顺手实现 candidate apply。
- 不把 memory-updater 的独立稳定性问题混进 Phase 14 contract。

### 本 stage 验收

- reviewer 能确认 Phase 14 建在 13E 之上，而不是绕回旧 evolution auto-apply 模型。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/control_plane_logger_cutover_test.exs`

## Stage 1

### 前置检查

- Stage 0 通过。
- `evolution.candidate.proposed` 已稳定写入 ControlPlane。

### 这一步改哪里

- 可新增 `lib/nex/agent/evolution/candidates.ex`
- `lib/nex/agent/control_plane/query.ex`
- `test/nex/agent/evolution_test.exs`
- `test/nex/agent/admin_test.exs`

### 这一步要做

- 新增 candidate lifecycle reducer：
  - 输入：`evolution.candidate.*` observations
  - 输出：derived candidate view
- 支持：
  - list recent candidates
  - fetch single candidate by id
  - reduce latest status
  - expose lifecycle observation ids
- 保持只读；不新增 state file。

### 实施注意事项

- 不从 `admin` 私有 event bus 读 candidate 状态。
- 不把 lifecycle status 缓存在 GenServer 长期 state。

### 本 stage 验收

- 同一 candidate id 的 status 可完全由 ControlPlane observations 推导。
- 删除所有 lifecycle observation 后，candidate 应消失，而不是残留在某个 state file。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/admin_test.exs`

## Stage 2

### 前置检查

- Stage 1 candidate reduction 可用。
- 已确认 owner/follow_up/subagent surface 边界。

### 这一步改哪里

- 可新增 `lib/nex/agent/tool/evolution_candidate.ex`
- `lib/nex/agent/tool/tool_list.ex`
- `lib/nex/agent/follow_up.ex`
- `test/nex/agent/tool_alignment_test.exs`
- `test/nex/agent/evolution_test.exs`

### 这一步要做

- 新增 owner-only deterministic tool `evolution_candidate`。
- `list` / `show` 走 Stage 1 candidate reduction。
- `approve` / `reject` 先写 lifecycle observations：
  - `evolution.candidate.approved`
  - `evolution.candidate.rejected`
- follow_up / subagent surface 不暴露 approve/reject。

### 实施注意事项

- 不把 approve/reject 做成 free-form bash/message side effect。
- 不允许 approve 一个不存在或已 superseded 的 candidate 并静默成功。

### 本 stage 验收

- owner run 能 deterministic 地 list/show/approve/reject。
- follow_up surface 仍然没有 candidate execution capability。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_test.exs`

## Stage 3

### 前置检查

- Stage 2 通过。
- `memory_write` / `soul_update` / `skill_create` 主链已确认可被 deterministic 调用。

### 这一步改哪里

- 可新增 `lib/nex/agent/evolution/executor.ex`
- `lib/nex/agent/tool/evolution_candidate.ex`
- `lib/nex/agent/tool/memory_write.ex`
- `lib/nex/agent/tool/soul_update.ex`
- `lib/nex/agent/tool/skill_create.ex`
- `test/nex/agent/evolution_integration_test.exs`

### 这一步要做

- 为 `memory_candidate` / `soul_candidate` / `skill_candidate` 增加 realization + apply 主链：
  - approve -> realization generated
  - apply started
  - call existing deterministic tool/module
  - apply completed / failed
- realization 可以是 bounded LLM plan，也可以是 deterministic mapping，但最终 apply 必须复用现有主链。

### 实施注意事项

- 不在 executor 内重写 memory/soul/skill 文件写入逻辑。
- apply failed 时必须写 `evolution.candidate.apply.failed`，不能只靠 Logger。
- 不允许未批准直接 apply。

### 本 stage 验收

- 非 code candidate 能在 owner approval 后沿既有主链落地。
- ControlPlane 能完整看到 proposed -> approved -> realized -> applied/failed lifecycle。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_integration_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_test.exs`

## Stage 4

### 前置检查

- Stage 2 通过。
- `phase10d/10e/10f` 的 CODE lane 和 `self_update` deploy contract 已确认。

### 这一步改哪里

- `lib/nex/agent/tool/evolution_candidate.ex`
- `lib/nex/agent/evolution/executor.ex`
- `lib/nex/agent/self_update/deployer.ex`
- `test/nex/agent/evolution_integration_test.exs`
- `test/nex/agent/self_modify_pipeline_test.exs`

### 这一步要做

- 为 `code_hint` 增加 approve path：
  - `mode=plan`：生成 execution plan / patch proposal observation
  - `mode=apply`：沿既有 CODE lane 执行，并通过 `self_update` deploy
- 记录 lifecycle：
  - `evolution.candidate.realization.generated`
  - `evolution.candidate.apply.started`
  - `evolution.candidate.apply.completed`
  - `evolution.candidate.apply.failed`

### 实施注意事项

- 不绕过 `self_update`。
- 不把 code candidate 执行写成隐藏版 `upgrade_code` 小系统。
- `mode=plan` 必须不修改代码或 deploy。

### 本 stage 验收

- `code_hint` 至少能稳定进入 `plan` lane，并留下可审计 observation。
- `mode=apply` 走既有 CODE deploy authority，不新增平行 deploy 入口。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_integration_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/self_modify_pipeline_test.exs`

## Stage 5

### 前置检查

- Stage 1-4 通过。
- candidate lifecycle reduction 已稳定。

### 这一步改哪里

- `lib/nex/agent/admin.ex`
- `lib/nex/agent/admin/event.ex`
- `lib/nex/agent/tool/reflect.ex`
- `test/nex/agent/admin_test.exs`
- `test/nex/agent/evolution_integration_test.exs`

### 这一步要做

- Admin 显示 pending/applied/failed/superseded candidates。
- `reflect evolution_status` / `evolution_history` 展示 candidate lifecycle，而不只显示 proposed 事件。
- 候选动作详情页/文本输出包含：
  - candidate id
  - status
  - risk
  - evidence ids
  - latest error

### 实施注意事项

- Admin / reflect 继续只读 candidate state。
- 不在 Admin 内缓存 candidate lifecycle。

### 本 stage 验收

- `admin` / `reflect` / `observe` 对同一 candidate id 的状态一致。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/admin_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_integration_test.exs`

## Stage 6

### 前置检查

- Stage 1-5 focused tests 通过。

### 这一步改哪里

- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/onboarding.ex`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`
- `test/nex/agent/context_builder_test.exs`

### 这一步要做

- prompt/onboarding 改成：
  - evolution proposes candidates
  - owner approves/rejects through the single execution lane
  - applied lifecycle is observable through ControlPlane
- progress 记录 Phase 14 开始与完成标志。

### 实施注意事项

- 不在文案里暗示 evolution 自动执行。
- 不给 follow_up 文案塞进 candidate apply 权限。

### 本 stage 验收

- agent guidance 与真实 owner-approved execution contract 对齐。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/context_builder_test.exs`

## Review Fail 条件

- 新增 candidate 平行状态文件或长期缓存。
- 同时出现多个 candidate apply/approve 工具入口。
- `evolution_candidate` 自己重写 memory/soul/skill/code apply 逻辑，而不是复用现有 deterministic lane。
- follow_up / subagent 获得 approve/reject/apply 权限。
- code candidate 绕过 `self_update` deploy authority。
- candidate lifecycle 缺 observation，导致 admin/reflect/observe 看不到同一条状态。
- candidate apply 失败只打 Logger，不写 ControlPlane observation。
- `mode=plan` 修改了代码或 deploy。
- `mode=apply` 默认自动执行高风险 code changes 而没有 owner approval record。
