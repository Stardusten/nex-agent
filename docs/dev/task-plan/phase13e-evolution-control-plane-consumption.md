# Phase 13E Evolution Control Plane Consumption

## 当前状态

Phase 13A/13B/13C/13D 的目标是让 ControlPlane 成为运行时观测的机器真相源。13E 是这个方向的消费端：Evolution / higher-level self-healing 不再维护或读取自己的平行观测状态，而是基于 ControlPlane observations、gauges、metrics、budget 做聚合和候选动作。

当前代码里的 evolution 主链仍有几个旧假设：

- `Nex.Agent.Evolution.record_signal/2` 写 `memory/patterns.jsonl`。
- `Evolution.read_signals/1` 从 `patterns.jsonl` 读行为信号。
- `Evolution.recent_events/1` 读 `Audit.recent/1` 并筛 `evolution.*`。
- `Evolution.run_evolution_cycle/1` 的输入主要是 HISTORY/MEMORY/SOUL/skills/signals，不以 ControlPlane observations 为第一 evidence。
- `SelfHealing.Aggregator` 仍围绕旧 event shape 聚合。
- Evolution 会直接应用 soul/memory/skill 更新；这和 Phase 13 对 budget 的约束不一致：budget 只能决定是否复盘/生成候选，不授权自动写 memory/skill/code 或 deploy。

13E 的目标是把自进化系统从“另一个事件系统 + 自动应用器”收口为“ControlPlane evidence consumer + budget-gated candidate generator”。

## 完成后必须达到的结果

1. Evolution 的 runtime evidence 只来自 ControlPlane Query/Gauge/Budget，不读 `memory/patterns.jsonl`、旧 self-healing store、raw log 文件或 Audit 私有文件。
2. Evolution cycle started/completed/failed/skipped/pattern/candidate 全部写 ControlPlane observations。
3. Self-healing higher-level aggregation 消费 ControlPlane observation envelope，不再消费旧 event shape。
4. Evolution prompt 使用 evidence pack：recent failures、repeated patterns、current run gauges、budget mode、candidate history。
5. Budget 控制 evolution depth：
   - sleep/low：不调用 LLM，只做 record/cheap summary
   - normal：允许 bounded quick/routine candidate generation
   - deep：允许 wider evidence window 和 deeper reflection
6. Evolution 输出 candidate actions，不自动 patch、deploy、写 memory、写 skill、写 SOUL。
7. Candidate actions 必须携带 evidence observation ids，便于 agent/user 追溯。
8. Existing prompts/onboarding/admin-facing copy 不再暗示 evolution 有独立事件日志或私有能量系统。

## 开工前必须先看的代码路径

- `docs/dev/task-plan/phase13-control-plane-observability.md`
- `docs/dev/task-plan/phase13a-minimal-control-plane-observability-cutover.md`
- `docs/dev/task-plan/phase13b-control-plane-runtime-lifecycle-observability.md`
- `docs/dev/task-plan/phase13c-run-control-follow-up-observability.md`
- `docs/dev/task-plan/phase13d-semantic-log-and-admin-query-cutover.md`
- `lib/nex/agent/control_plane/query.ex`
- `lib/nex/agent/control_plane/budget.ex`
- `lib/nex/agent/control_plane/log.ex`
- `lib/nex/agent/control_plane/metric.ex`
- `lib/nex/agent/control_plane/gauge.ex`
- `lib/nex/agent/evolution.ex`
- `lib/nex/agent/self_healing/aggregator.ex`
- `lib/nex/agent/self_healing/router.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/onboarding.ex`
- `lib/nex/agent/admin.ex`
- `test/nex/agent/evolution_test.exs`
- `test/nex/agent/evolution_integration_test.exs`
- `test/nex/agent/self_healing_aggregator_test.exs`
- `test/nex/agent/self_healing_router_test.exs`
- `test/nex/agent/context_builder_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. 13E 开工前置条件冻结：

```text
13D must be complete first:
- semantic Logger cutover is done or explicitly allowlisted
- Audit / RequestTrace / Admin observability surfaces read ControlPlane or are no longer machine truth
- observe remains the only agent-facing observation query tool
```

如果 13D 未完成，不进入 13E。Evolution 不能消费一个尚未收口的半真相源。

13E 开工前必须有一个显式 pause：

```text
pause before 13E implementation:
- review the remaining direct Logger allowlist
- migrate or delete any semantic Logger that still carries machine facts
- rerun the 13D logger-cutover focused tests
```

这个 pause 不是新的 phase，而是 13E Stage 0 的硬前置。目标是确保进入 13E 时，ControlPlane 真的是 evolution 唯一运行时证据源。

2. Evolution evidence source 冻结：

```text
allowed machine evidence:
- ControlPlane.Query.query/2
- ControlPlane.Query.summary/1
- ControlPlane.Query.incident/2
- ControlPlane.Gauge.all/1
- ControlPlane.Budget.current/1
- ControlPlane.Budget.mode/1

context-only inputs:
- MEMORY.md
- SOUL.md
- skill list
- recent conversation history
```

MEMORY/SOUL/skills/history 可以作为 reflection context，但不能替代 runtime evidence。

3. Removed machine truth sources：

```text
memory/patterns.jsonl
SelfHealing.EventStore
SelfHealing.EnergyLedger
Audit.recent as private truth
/tmp/nex-agent-gateway.log
```

旧 `memory/patterns.jsonl` 不再作为 evolution 输入。是否删除文件由 migration stage 决定，但代码不能再读它作为机器真相源。

4. Evolution observation tags 冻结为点分字符串：

```text
evolution.signal.recorded
evolution.cycle.started
evolution.cycle.skipped
evolution.cycle.completed
evolution.cycle.failed
evolution.pattern.detected
evolution.candidate.proposed
evolution.budget.spend.failed
```

不得继续新增 `evolution.cycle_started` 这种 underscore tag。

5. Evidence pack shape 冻结：

```elixir
%{
  "trigger" => "manual" | "post_consolidation" | "scheduled_daily" | "scheduled_weekly",
  "profile" => "quick" | "routine" | "deep",
  "budget" => %{
    "mode" => "sleep" | "low" | "normal" | "deep",
    "current" => non_neg_integer(),
    "capacity" => pos_integer()
  },
  "window" => %{
    "since" => String.t() | nil,
    "limit" => pos_integer()
  },
  "observations" => [
    %{
      "id" => String.t(),
      "timestamp" => String.t(),
      "tag" => String.t(),
      "level" => String.t(),
      "kind" => String.t(),
      "context" => map(),
      "attrs_summary" => map()
    }
  ],
  "patterns" => [
    %{
      "tag" => String.t(),
      "count" => pos_integer(),
      "severity" => "info" | "warning" | "error" | "critical",
      "actors" => [String.t()],
      "sample_ids" => [String.t()],
      "first_seen" => String.t(),
      "last_seen" => String.t()
    }
  ],
  "current_runs" => [map()],
  "candidate_history" => [map()]
}
```

`attrs_summary` is bounded and redacted. It must not contain full prompt, full response, full tool args, headers, body, patch content, or raw logs.

6. Candidate action shape 冻结：

```elixir
%{
  "id" => String.t(),
  "kind" =>
    "record_only"
    | "reflection_candidate"
    | "memory_candidate"
    | "skill_candidate"
    | "soul_candidate"
    | "code_hint",
  "summary" => String.t(),
  "rationale" => String.t(),
  "evidence_ids" => [String.t()],
  "risk" => "low" | "medium" | "high",
  "requires_owner_approval" => true,
  "created_at" => String.t()
}
```

All candidate actions require owner approval. 13E does not introduce automatic apply/deploy.

7. Budget mode behavior freezes：

```text
sleep:
- no LLM
- no candidate generation beyond record_only

low:
- no LLM
- cheap aggregation and maybe reflection_candidate

normal:
- bounded LLM reflection allowed for quick/routine profile
- max observation window <= 100

deep:
- bounded LLM reflection allowed for deep profile
- max observation window <= 500
```

Budget spend failure writes `evolution.budget.spend.failed` and skips deeper work.

8. Evolution public behavior freezes：

```elixir
Evolution.run_evolution_cycle(opts) ::
  {:ok, %{
    status: :completed | :skipped,
    trigger: atom(),
    profile: atom(),
    budget_mode: atom(),
    evidence_count: non_neg_integer(),
    pattern_count: non_neg_integer(),
    candidate_count: non_neg_integer(),
    candidates: [map()]
  }}
  | {:error, term()}
```

The return value is candidate-oriented. It does not report applied memory/soul/skill/code changes.

9. `Evolution.record_signal/2` boundary：

If the function remains, it must write `evolution.signal.recorded` to ControlPlane only. It must not write `patterns.jsonl`.

Callers may instead be migrated to `ControlPlane.Log.*` directly. Do not keep two signal stores.

10. Prompt/onboarding boundary：

```text
Evolution guidance may say:
- use observe to inspect ControlPlane evidence
- candidate actions require owner approval
- budget controls depth/frequency

Evolution guidance must not say:
- inspect self_healing event store
- inspect patterns.jsonl
- budget authorizes automatic memory/skill/code writes
- evolution can deploy on its own
```

## 执行顺序 / stage 依赖

- Stage 0：13D residual closeout pause，确认 semantic Logger 收口完成，再验证 13D completion 和 13A/13B/13C review findings。
- Stage 1：迁移 evolution signal/audit emissions 到 ControlPlane。
- Stage 2：新增 ControlPlane evidence pack builder。
- Stage 3：迁移 SelfHealing Aggregator 到 observation envelope。
- Stage 4：接入 Budget gating 和 profile window。
- Stage 5：重写 Evolution reflection 输出为 candidate actions。
- Stage 6：Prompt/onboarding/admin/progress 收尾。

Stage 1 依赖 Stage 0。  
Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 2。  
Stage 4 依赖 Stage 2。  
Stage 5 依赖 Stage 3、Stage 4。  
Stage 6 依赖 Stage 5。  

## Stage 0

### 前置检查

- 13A/13B/13C focused tests 通过。
- 13D 已完成 Logger/Audit/RequestTrace/Admin 观测面收口。
- 13D logger allowlist review 已完成，剩余 direct `Logger.*` 都已经被归类为 projection/fallback/boot/third-party boundary。

### 这一步改哪里

- `docs/dev/task-plan/phase13d-semantic-log-and-admin-query-cutover.md`
- `lib/nex/agent/evolution.ex`
- `lib/nex/agent/self_healing/aggregator.ex`
- `test/nex/agent/evolution_test.exs`
- `test/nex/agent/self_healing_aggregator_test.exs`
- `test/nex/agent/control_plane_logger_cutover_test.exs`

### 这一步要做

- 确认没有旧 `SelfHealing.EventStore` / `EnergyLedger` 主链。
- 确认 `Audit.recent/1` 不再是 evolution machine truth。
- 确认 semantic Logger cutover 已完成或 allowlisted。
- 确认 `observe` 仍是唯一 agent-facing observation query tool。
- 显式暂停检查 13D residual：
  - 逐个复核 `control_plane_logger_cutover_test.exs` 里的 allowlist 文件和 call patterns。
  - 迁移仍承载 workspace/session/run/status/duration/job outcome 等机器事实的 direct `Logger.*`。
  - 不允许带着“整文件大赦”进入 13E。

### 实施注意事项

- 不在 13E Stage 1-6 中继续夹带 13D 收尾；Stage 0 必须先把 residual semantic Logger 问题停下来收干净。
- 这个 pause 只做 13D residual closeout，不提前实现 13E evidence/budget/candidate 行为。

### 本 stage 验收

- Evolution 的所有后续输入都能从 ControlPlane 获取。
- reviewer 能确认 13E 启动前，remaining direct `Logger.*` 已经不再承载 machine truth。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/observe_tool_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/control_plane_store_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/control_plane_logger_cutover_test.exs`

## Stage 1

### 前置检查

- Stage 0 通过。
- 已列出 `Evolution.record_signal/2`、`Evolution.recent_events/1`、`Audit.append("evolution.*")` 所有调用点。

### 这一步改哪里

- `lib/nex/agent/evolution.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/admin.ex`
- `test/nex/agent/evolution_test.exs`
- `test/nex/agent/evolution_integration_test.exs`

### 这一步要做

- `record_signal/2` 改为写 `ControlPlane.Log.info("evolution.signal.recorded", ...)`，或删除并迁移调用点直接写 ControlPlane。
- `recent_events/1` 改为通过 `ControlPlane.Query.query/2` 查询 `evolution.*` tags。
- `run_evolution_cycle/1` started/completed/failed/skipped 全部写 ControlPlane tags。
- 删除 `patterns.jsonl` 作为测试断言来源。

### 实施注意事项

- 不保留 `patterns.jsonl` + ControlPlane 双写。
- 不把旧 Audit event shape 包进 ControlPlane attrs 当兼容层。
- Observation attrs 必须携带 trigger/profile/budget_mode 等机器字段。

### 本 stage 验收

- Evolution cycle events 可通过 `ControlPlane.Query` 查询。
- `memory/patterns.jsonl` 不再增长。
- Tests 不再读 `Audit.recent/1` 或 `patterns.jsonl` 验证 evolution runtime facts。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_integration_test.exs`

## Stage 2

### 前置检查

- Stage 1 通过。
- ControlPlane Query 支持 tag/level/run_id/session_key/query/since/limit。

### 这一步改哪里

- `lib/nex/agent/evolution.ex`
- 可新增 `lib/nex/agent/evolution/evidence.ex`
- `test/nex/agent/evolution_test.exs`

### 这一步要做

- 新增 evidence pack builder。
- Query recent warning/error/critical observations。
- Query evolution candidate history。
- Read current gauges, especially `run.owner.current`。
- Include budget state/mode。
- Bound and redact attrs into `attrs_summary`。

### 实施注意事项

- 不读取 raw JSONL 文件；只用 `ControlPlane.Query`。
- 不把 full observation attrs 原样塞进 prompt。
- Evidence pack sample ids 必须能追溯到 original observation id。

### 本 stage 验收

- Unit test 构造 ControlPlane observations 后，evidence pack 包含 expected observations/patterns/current_runs/budget。
- Secret strings 不进入 evidence pack。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_test.exs`

## Stage 3

### 前置检查

- Stage 2 evidence pack 可用。

### 这一步改哪里

- `lib/nex/agent/self_healing/aggregator.ex`
- `lib/nex/agent/self_healing/router.ex`
- `test/nex/agent/self_healing_aggregator_test.exs`
- `test/nex/agent/self_healing_router_test.exs`

### 这一步要做

- Aggregator 接受 ControlPlane observation envelope。
- 聚合字段使用 `tag`、`level`、`context`、`attrs.actor`、`attrs.tool_name`、`attrs.reason_type`。
- 输出 patterns shape，供 evidence pack 和 Evolution 使用。
- Router 若还需要 repeated summary，也从 ControlPlane observation summary 获取。

### 实施注意事项

- 不恢复旧 `"name"` event contract。
- 不新增 SelfHealing 私有 store。
- 不把 router 决策升级为自动 patch/deploy。

### 本 stage 验收

- Repeated `runner.tool.call.failed` / `http.request.failed` / `self_update.deploy.failed` 能聚合为 patterns。
- Aggregator tests 不再构造旧 self-healing event shape。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/self_healing_aggregator_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/self_healing_router_test.exs`

## Stage 4

### 前置检查

- Stage 2 evidence pack 可用。
- `ControlPlane.Budget` 当前/spend/mode 可用。

### 这一步改哪里

- `lib/nex/agent/evolution.ex`
- `lib/nex/agent/control_plane/budget.ex`
- `test/nex/agent/evolution_test.exs`
- `test/nex/agent/control_plane_budget_test.exs`

### 这一步要做

- `run_evolution_cycle/1` 根据 Budget mode 决定是否跳过、cheap summary、LLM reflection。
- `Budget.spend/3` 使用 action：
  - `evolution.quick`
  - `evolution.routine`
  - `evolution.deep`
- spend 失败写 `evolution.budget.spend.failed` 并返回 skipped。
- Evidence window 根据 profile/mode 限制。

### 实施注意事项

- Budget 不授权自动写 memory/skill/soul/code。
- sleep/low 不调用 LLM。
- Spend failure 不应该崩溃 owner run。

### 本 stage 验收

- sleep mode returns skipped without LLM call。
- normal/deep mode consumes budget and runs bounded path。
- spend failure produces ControlPlane observation。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/control_plane_budget_test.exs`

## Stage 5

### 前置检查

- Stage 2、3、4 通过。

### 这一步改哪里

- `lib/nex/agent/evolution.ex`
- `test/nex/agent/evolution_test.exs`
- `test/nex/agent/evolution_integration_test.exs`

### 这一步要做

- Reflection prompt 使用 evidence pack，而不是 raw signals。
- `evolution_report` tool schema 改为输出 candidate actions。
- `apply_updates/2` 改名或删除；cycle 返回 candidates，不自动写 SOUL/MEMORY/skills/code。
- 每个 candidate 写 `evolution.candidate.proposed` observation。
- `evolution.cycle.completed` attrs 包含 evidence_count/pattern_count/candidate_count。

### 实施注意事项

- 不把旧 soul/memory/skill auto-write 保留为 hidden side effect。
- Code hints 仍只是 hints/candidates，不能调用 `self_update`。
- Candidate content 必须 bounded/redacted；skill draft content 不应自动写入 skill files in 13E。

### 本 stage 验收

- Evolution returns candidate list with evidence_ids。
- No SOUL.md / MEMORY.md / skills files are modified by `run_evolution_cycle/1`。
- Candidate observations can be found by `observe query tag=evolution.candidate.proposed`。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_integration_test.exs`

## Stage 6

### 前置检查

- Stage 1-5 focused tests 通过。

### 这一步改哪里

- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/onboarding.ex`
- `lib/nex/agent/admin.ex`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`
- `test/nex/agent/context_builder_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

### 这一步要做

- Prompt/onboarding 改成 “Evolution consumes ControlPlane evidence and proposes candidates.”
- Admin/evolution status 若存在，显示 candidate counts/evidence ids/budget mode。
- Progress 记录 13E 完成后，Phase 13 ControlPlane observability 主线闭环完成。

### 实施注意事项

- 不重新引入 Audit/private history as machine truth。
- 不扩大 agent-facing tools。

### 本 stage 验收

- 用户和 agent 文案都不再提 `patterns.jsonl`、private event store、private energy ledger。
- Evolution status/history 与 observe 看到的 `evolution.*` observations 一致。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/context_builder_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_test.exs`

## Review Fail 条件

- 13D 未完成就让 Evolution 消费 ControlPlane。
- Evolution 仍读 `memory/patterns.jsonl`、旧 EventStore、旧 EnergyLedger、raw log file 或 Audit 私有文件作为机器真相源。
- Evolution 同时写 `patterns.jsonl` 和 ControlPlane。
- Evolution tags 使用 underscore form，如 `evolution.cycle_started`。
- Evidence pack 存 full prompt、full response、full tool args、headers、body、patch content、raw logs 或 secret 明文。
- Budget sleep/low mode 仍调用 LLM。
- Budget spend failure 仍继续 deep reflection。
- `run_evolution_cycle/1` 自动写 SOUL/MEMORY/skills/code 或调用 deploy。
- Candidate action 没有 evidence_ids，无法追溯到 ControlPlane observations。
- SelfHealing Aggregator 仍依赖旧 `"name"` event shape。
- Prompt/onboarding/admin 文案仍把 private event store / patterns file / energy ledger 描述为可查真相源。
