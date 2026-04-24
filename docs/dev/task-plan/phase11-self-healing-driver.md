# Phase 11 Self-Healing Driver

## 当前状态

Phase 10a-f 把 CODE 层自我迭代的关键工具面和部署控制面补了起来：

- agent 可以通过 `find -> read/reflect -> apply_patch -> self_update status/deploy` 看代码、改代码、预检并激活。
- `self_update` 是唯一 CODE runtime activation 入口，负责 plan、syntax、compile/reload、related tests、release store、snapshot、rollback、history/status。
- subagent 可以 inspect/patch，但 owner run 才能 deploy/rollback。
- Evolution / Memory / Skill 已有基础：会话可刷新 MEMORY，Evolution 可读取 HISTORY/MEMORY/SOUL/skills/signals，生成 soul/memory/skill/code hint。

但当前系统仍缺少自愈/自迭代驱动层：

- Runner 只统计局部 tool errors / complexity，没有把关键边界失败稳定记录为结构化事件。
- `Evolution.record_signal/2` 和 `maybe_trigger_after_consolidation/1` 不是所有失败链路的统一入口。
- LLM 失败、tool 失败、deploy 失败、memory 失败、channel 失败等事件没有统一命名、预算、归因、复盘和演进策略。
- Hermes Agent 的 security immunity 说明了“周期复盘 + 持久化 skill/memory”可以从攻击链中生成防御能力，但 Nex 不应只复制 security prompt，而应建设通用 runtime hook / self-healing substrate。
- 这不是普通重构。目标不是一次性落地完整蓝图，而是先做一个低成本、预算驱动、可扩展的最小闭环，让系统在真实失败中摸索方向。

## 完成后必须达到的结果

Phase 11 结束时，Nex 必须从“有自修改工具”演进为“有自愈驱动系统”：

1. 关键 runtime 边界能发出统一结构化事件，而不是散落日志、计数器和自由文本。
2. 事件进入一个低成本 router，根据类型、频率、严重度、预算和能量状态决定是否只记录、做 deterministic recovery、触发 bounded reflection，或进入 long-path evolution。
3. 自愈系统有能量/代谢模型。能量低时只记录和压缩，能量足够时才做 LLM 复盘、memory/skill candidate、code hint 或 patch proposal。
4. 自迭代不会在 hot path 里无限消耗 token。默认路径必须 cheap-first，只有聚合后达到阈值才调用 LLM。
5. 所有 CODE 层实际激活仍只走 `self_update deploy`，并保持 owner-only deploy。
6. Memory / skill / policy / code 的持久化强度不同。越持久、越高 blast radius 的变更，需要越高能量、证据、置信度和控制边界。
7. 安全免疫作为 Phase 11 的一个长路径 profile，而不是第一步唯一目标。跨 turn 攻击链检测、policy memory、quarantine 和 provenance 后续建立在同一事件/能量系统上。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/task-plan/phase10-self-iteration-foundation.md`
- `docs/dev/task-plan/phase10d-self-update-deploy-control-plane.md`
- `docs/dev/task-plan/phase10e-code-editing-toolchain-reset.md`
- `docs/dev/task-plan/phase10f-self-iteration-ux-and-release-visibility.md`
- `docs/deep-research-report.md`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/llm/req_llm.ex`
- `lib/nex/agent/memory_updater.ex`
- `lib/nex/agent/evolution.ex`
- `lib/nex/agent/self_update/deployer.ex`
- `lib/nex/agent/self_update/release_store.ex`
- `lib/nex/agent/audit.ex`
- `lib/nex/agent/bus.ex`
- `lib/nex/agent/cron.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/onboarding.ex`

## 固定边界 / 已冻结的数据结构与 contract

1. Phase 11 是探索式驱动计划，不是一次性重构。

```text
principle:
- first make the self-iteration loop run
- keep the first loop cheap and bounded
- expand hook coverage only after observed value
- never require a perfect substrate before useful learning starts
```

2. 三条 recovery lane 冻结为：

```text
hot path:
- deterministic
- low token or zero token
- reversible or low blast radius
- examples: retry, backoff, provider fallback, schema repair, rollback-first failure handling

near path:
- bounded reflective diagnosis
- reads compact structured summaries, not full raw traces
- can produce hints, routing advice, temporary guard suggestions, memory/skill/code candidates
- must not deploy CODE

long path:
- asynchronous evolution over repeated or high-value episodes
- can produce durable memory candidates, skill drafts, policy signatures, code hints, patch proposals
- CODE activation still requires owner run + self_update deploy
```

3. 能量/代谢模型是 Phase 11 的核心控制机制。

最小 shape：

```elixir
%{
  capacity: non_neg_integer(),
  current: non_neg_integer(),
  mode: :sleep | :low | :normal | :deep,
  refill_rate: non_neg_integer(),
  last_refilled_at: String.t(),
  spent_today: non_neg_integer()
}
```

4. 能量档位冻结为策略概念，具体数字允许在实现中微调，但语义不能变。

```text
sleep:
- only append events
- no LLM reflection
- no persistent memory/skill/code candidates

low:
- append events
- deterministic aggregation
- tiny runtime hints allowed

normal:
- bounded reflective diagnosis allowed
- memory candidate / skill draft allowed when evidence is clear

deep:
- code inspection / patch proposal / security chain review allowed
- still no direct CODE activation
```

5. 自愈动作必须消耗能量。第一版可从固定 cost table 起步。

```text
record_event: 0
aggregate_signals: 1
deterministic_retry: 1
inject_small_hint: 2
reflective_diagnosis: 8-15
memory_candidate: 10
skill_draft: 15
code_inspection: 20
patch_proposal: 30
self_update_deploy_attempt: 40+
```

6. 结构化事件 namespace 初始方向冻结为：

```text
llm.call.failed
llm.response.invalid
tool.call.failed
tool.security.blocked
tool.loop.detected
self_update.deploy.failed
self_update.rollback.failed
memory.refresh.failed
skill_runtime.prepare_failed
channel.send.failed
cron.job.failed
user.correction.detected
test.failed
runtime.reload.changed
```

7. 第一版事件 envelope 允许比 deep research report 简化，但必须保留可扩展字段。

```elixir
%{
  id: String.t(),
  timestamp: String.t(),
  name: String.t(),
  phase: String.t(),
  severity: String.t(),
  run_id: String.t() | nil,
  session_key: String.t() | nil,
  workspace: String.t(),
  actor: map(),
  classifier: map(),
  evidence: map(),
  energy_cost: non_neg_integer(),
  decision: map() | nil,
  outcome: map() | nil
}
```

8. Token budget rule：

```text
Do not call LLM per failure by default.
LLM reflection only sees compact summaries.
Raw traces stay in durable event files and are referenced by id.
Repeated known failures should be handled by deterministic aggregation and cached diagnosis.
```

9. CODE activation boundary remains frozen from Phase 10:

```text
patch proposal != deploy
subagent patch != deploy
near-path diagnosis != deploy
long-path evolution != deploy
only owner run can call self_update status/deploy/rollback
```

10. Memory / skill / policy outputs must carry provenance and trust state before they influence behavior.

Initial trust classes:

```text
tool_observed
self_inferred
security_hypothesis
human_confirmed
quarantined
```

Security-relevant long-path output defaults to `quarantined` until later phases explicitly define promotion.

## 执行顺序 / stage 依赖

- Phase 11a：Minimal Self-Healing Loop。先接最少事件、最小 event store、能量账本和 cheap aggregator，让闭环跑起来。
- Phase 11b：Hot-Path Recovery Registry。把已知 recoverable failure 接成 deterministic handlers 和 circuit breaker。
- Phase 11c：Reflective Diagnosis Worker。能量允许时用 compact summaries 做 bounded LLM 诊断，产出 typed remediation。
- Phase 11d：Evolution Event Consumer。让 Evolution 消费结构化事件 batch，输出 typed memory / skill draft / policy signature / code hint。
- Phase 11e：Security Chain Immunity。基于事件序列识别跨 turn post-exploitation / prompt injection / memory poisoning 模式，并走 policy memory + quarantine。
- Phase 11f：Replay-Aware SelfUpdate。把 release、event graph、历史失败和 user correction 连接到 deploy/replay verification。

11b 依赖 11a。  
11c 依赖 11a。  
11d 依赖 11a 和 11c。  
11e 依赖 11a 和 11d。  
11f 依赖 11a 和 Phase 10d/10f。  

## Stage 11a

详见 [Phase 11A Minimal Self-Healing Loop](./phase11a-minimal-self-healing-loop.md)。

### 前置检查

- Phase 10d/e/f 的 CODE 自更新主链已存在。
- 不要求完整 hook substrate。
- 不要求接入所有失败事件。

### 这一步改哪里

- 新增 `lib/nex/agent/self_healing/event_store.ex`
- 新增 `lib/nex/agent/self_healing/energy_ledger.ex`
- 新增 `lib/nex/agent/self_healing/aggregator.ex`
- 新增 `lib/nex/agent/self_healing/router.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/self_update/deployer.ex`
- `lib/nex/agent/onboarding.ex`
- `lib/nex/agent/context_builder.ex`
- 新增 `test/nex/agent/self_healing_*_test.exs`

### 这一步要做

- 只接三类事件：
  - `tool.call.failed`
  - `llm.call.failed`
  - `self_update.deploy.failed`
- 写 repo/workspace 内 append-only `runtime_events.jsonl`。
- 写最小 `energy.json`。
- 写 cheap aggregator，不调用 LLM。
- Router 根据能量和聚合结果返回 `:record_only | :hint_candidate | :reflect_candidate`，但 11a 不实现 LLM reflection。

### 实施注意事项

- 不要一开始接所有子系统。
- 不要一开始引入 GenServer 长期状态，除非有明确并发需求。
- 不要让 hook 失败影响主业务路径。
- 不要把 event store 放进安全禁区。

### 本 stage 验收

- 失败事件能稳定写入 durable event store。
- 能量账本能限制自愈动作强度。
- 同类失败能被 aggregator 合并成 compact summary。
- 主 run 不因 self-healing 写入失败而失败。

### 本 stage 验证

- `mix test test/nex/agent/self_healing_event_store_test.exs`
- `mix test test/nex/agent/self_healing_energy_ledger_test.exs`
- `mix test test/nex/agent/self_healing_aggregator_test.exs`
- `mix test test/nex/agent/runner_evolution_test.exs`
- `mix test test/nex/agent/self_modify_pipeline_test.exs`

## Review Fail 条件

- 试图一次性实现完整 hook 平台，导致第一步无法闭环。
- 每次失败都直接调用 LLM。
- 自愈系统无预算/能量限制。
- near/long path 可以直接 deploy CODE。
- self-healing 写入失败会让用户主任务失败。
- 事件只写自由文本，无法做稳定聚合。
- Memory/skill/security 输出没有 provenance/trust 边界。
- 新增第二条 CODE activation 主链。
