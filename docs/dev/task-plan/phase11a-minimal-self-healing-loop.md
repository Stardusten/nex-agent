# Phase 11A Minimal Self-Healing Loop

## 当前状态

Phase 11 的总目标是建立 runtime hook / self-healing spine，但这不是普通重构。我们还不知道最终最有效的 hook 覆盖面、复盘策略和安全免疫形态，所以 11a 只做能让自我迭代转起来的最小闭环：

```text
出事 -> 记录结构化信号 -> 低成本聚合 -> 根据能量决定是否给出复盘候选 -> 后续阶段再接 LLM reflection / evolution
```

当前代码里已有可复用基础：

- `Runner` 能看到 LLM 调用失败、tool call 结果、loop 检测和当前 run/session 上下文。
- `Tool.Registry` 能执行工具并捕获 crash/timeout。
- `SelfUpdate.Deployer` 能返回 deploy/test/rollback 失败结构。
- `Evolution.record_signal/2` 存在，但还不是统一 runtime hook 入口。
- `Audit` / `Bus` 存在，但不应直接变成自愈事件真相源，11a 需要一个更小、更稳定的 self-healing event store。

## 完成后必须达到的结果

1. Nex 有一个最小 self-healing event store，能把三类高价值失败记录为结构化 JSONL：
   - `tool.call.failed`
   - `llm.call.failed`
   - `self_update.deploy.failed`
2. Nex 有一个最小 energy ledger，能表达当前自愈系统处于 `:sleep | :low | :normal | :deep` 哪个能量档位。
3. Nex 有一个 cheap aggregator，不调用 LLM，只基于最近事件计算同类失败次数、连续失败、影响对象和 compact summary。
4. Nex 有一个 router，根据事件、聚合结果和能量，返回 bounded decision：
   - `:record_only`
   - `:hint_candidate`
   - `:reflect_candidate`
5. 11a 不做真正 LLM reflection，不写 memory/skill/code patch，不做自动 deploy。它只产出“下一步值得复盘”的候选信号。
6. self-healing 任何失败都不能破坏用户主任务。hook 写入失败只记录 logger warning。
7. 所有存储落在 workspace/repo 内，不访问安全禁区。

## 开工前必须先看的代码路径

- `docs/dev/task-plan/phase11-self-healing-driver.md`
- `docs/deep-research-report.md`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/self_update/deployer.ex`
- `lib/nex/agent/evolution.ex`
- `lib/nex/agent/workspace.ex`
- `lib/nex/agent/audit.ex`
- `test/nex/agent/runner_evolution_test.exs`
- `test/nex/agent/self_modify_pipeline_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. 11a 只接三类事件。

```text
tool.call.failed
llm.call.failed
self_update.deploy.failed
```

不接 memory/channel/cron/security chain/replay，避免第一步失控。

2. Event store 路径冻结为 workspace 内。

```text
<workspace>/self_healing/runtime_events.jsonl
<workspace>/self_healing/energy.json
```

如果调用方没有 workspace，则使用 `Nex.Agent.Workspace.root/0`。不得使用 `~/.nex`。

3. Event envelope 最小 shape：

```elixir
%{
  "id" => String.t(),
  "timestamp" => String.t(),
  "name" => String.t(),
  "phase" => String.t(),
  "severity" => String.t(),
  "run_id" => String.t() | nil,
  "session_key" => String.t() | nil,
  "workspace" => String.t(),
  "actor" => map(),
  "classifier" => map(),
  "evidence" => map(),
  "energy_cost" => non_neg_integer(),
  "decision" => map() | nil,
  "outcome" => map() | nil
}
```

4. Evidence 必须短摘要，不保存大段 raw trace。

```text
error_text max 1000 chars
tool args summary max 1000 chars
llm error summary max 1000 chars
self_update error summary max 1000 chars
```

长内容后续用 artifact reference，本 stage 不实现 blob store。

5. Energy ledger 最小 shape：

```elixir
%{
  "capacity" => 100,
  "current" => non_neg_integer(),
  "mode" => "sleep" | "low" | "normal" | "deep",
  "refill_rate" => non_neg_integer(),
  "last_refilled_at" => String.t(),
  "spent_today" => non_neg_integer()
}
```

`refill_rate` 表示每小时恢复的 energy 点数；`current/1` 读取 ledger 时按 `last_refilled_at` 做轻量恢复并封顶到 `capacity`，不新增长期进程。

6. 11a 固定 energy mode 语义：

```text
sleep:
- only record events
- router always returns record_only

low:
- allow aggregate_signals
- router may return hint_candidate for repeated failures

normal:
- router may return reflect_candidate for repeated or critical failures

deep:
- same as normal in 11a
- reserved for 11c+ code/security deeper work
```

7. 11a cost table：

```text
record_event: 0
aggregate_signals: 1
hint_candidate: 2
reflect_candidate: 8
```

8. Aggregator input/output shape：

```elixir
input:
%{
  event: map(),
  recent_events: [map()]
}

output:
%{
  status: :ok,
  window_size: non_neg_integer(),
  same_name_count: non_neg_integer(),
  same_actor_count: non_neg_integer(),
  consecutive_count: non_neg_integer(),
  summary: String.t(),
  repeated?: boolean()
}
```

9. Router decision shape：

```elixir
%{
  action: :record_only | :hint_candidate | :reflect_candidate,
  reason: String.t(),
  energy_mode: :sleep | :low | :normal | :deep,
  energy_spent: non_neg_integer(),
  summary: String.t() | nil
}
```

10. Hook safety boundary：

```text
self-healing code must never raise into the primary run
self-healing code must never call LLM in 11a
self-healing code must never write MEMORY/SKILL/CODE in 11a
self-healing code must never call self_update deploy in 11a
```

## 执行顺序 / stage 依赖

- Stage 1：新增 self_healing event store 和 energy ledger。
- Stage 2：新增 aggregator/router，完成 cheap decision。
- Stage 3：接入 Runner tool/LLM failure 和 SelfUpdate deploy failure。
- Stage 4：补 prompt/onboarding 极小说明和测试。

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1、Stage 2。  
Stage 4 依赖 Stage 3。  

## Stage 1

### 前置检查

- 确认 `Nex.Agent.Workspace.root/0` 和 workspace opts 的用法。
- 确认没有读取安全禁区。
- 确认 event 写入失败可以只 logger warning。

### 这一步改哪里

- 新增 `lib/nex/agent/self_healing/event_store.ex`
- 新增 `lib/nex/agent/self_healing/energy_ledger.ex`
- 新增 `test/nex/agent/self_healing_event_store_test.exs`
- 新增 `test/nex/agent/self_healing_energy_ledger_test.exs`

### 这一步要做

- `EventStore.append/2`：追加 JSONL event，自动补 id/timestamp/workspace。
- `EventStore.recent/2`：读取最近 N 条 event，坏行跳过。
- `EnergyLedger.current/1`：读取或初始化 energy state。
- `EnergyLedger.spend/3`：能量足够则扣除并返回更新状态；不足返回 `{:error, :insufficient_energy}`。
- `EnergyLedger.mode/1`：根据 current 计算 mode。

### 实施注意事项

- 不要用 GenServer。
- 不要缓存长期状态。
- 不要把 energy 写到 repo `.nex_self_update`，它属于 workspace self-healing 状态。

### 本 stage 验收

- JSONL event 可追加、可读取、坏行不影响读取。
- energy 初始化稳定。
- spend 成功/失败语义明确。

### 本 stage 验证

- `mix test test/nex/agent/self_healing_event_store_test.exs`
- `mix test test/nex/agent/self_healing_energy_ledger_test.exs`

## Stage 2

### 前置检查

- Stage 1 已完成。
- Event shape 和 energy shape 已冻结。

### 这一步改哪里

- 新增 `lib/nex/agent/self_healing/aggregator.ex`
- 新增 `lib/nex/agent/self_healing/router.ex`
- 新增 `test/nex/agent/self_healing_aggregator_test.exs`
- 新增 `test/nex/agent/self_healing_router_test.exs`

### 这一步要做

- Aggregator 从最近事件中计算：
  - same event name count
  - same actor count
  - consecutive same name/actor count
  - repeated? flag
  - short summary
- Router 决策：
  - sleep -> `record_only`
  - low + repeated -> `hint_candidate`
  - normal/deep + repeated or severity critical -> `reflect_candidate`
  - energy 不足 -> `record_only`

### 实施注意事项

- 11a 的 router 不调用 LLM。
- `reflect_candidate` 只是候选，不触发真正 reflection。
- summary 必须短，适合后续塞进 LLM prompt。

### 本 stage 验收

- 同类连续失败能被识别。
- 能量不足时不会升级。
- router 输出稳定 shape。

### 本 stage 验证

- `mix test test/nex/agent/self_healing_aggregator_test.exs`
- `mix test test/nex/agent/self_healing_router_test.exs`

## Stage 3

### 前置检查

- Stage 2 已完成。
- 只接三类事件，不扩大 scope。

### 这一步改哪里

- `lib/nex/agent/runner.ex`
- `lib/nex/agent/self_update/deployer.ex`
- 新增或更新 `test/nex/agent/runner_evolution_test.exs`
- 新增或更新 `test/nex/agent/self_modify_pipeline_test.exs`

### 这一步要做

- Runner 在 LLM call 最终失败时 emit `llm.call.failed`。
- Runner 在 tool result 为 `Error:` 时 emit `tool.call.failed`。
- SelfUpdate deploy 返回 failed result 时 emit `self_update.deploy.failed`。
- 每次 emit 都走：

```text
EventStore.append
EventStore.recent
Aggregator.summarize
Router.decide
EventStore.update or append decision event
```

如果其中任何一步失败，只 logger warning，不改变主结果。

### 实施注意事项

- 不要在 Tool.Registry 里重复 emit 同一事件，11a 先从 Runner 统一观察 tool result。
- 不要在 `self_update rollback` 接事件，留给后续阶段。
- 不要把完整 tool args 或 LLM response 存进去。

### 本 stage 验收

- tool failure 会产生 JSONL event。
- LLM failure 会产生 JSONL event。
- deploy failure 会产生 JSONL event。
- 主业务返回值保持原语义。

### 本 stage 验证

- `mix test test/nex/agent/runner_evolution_test.exs`
- `mix test test/nex/agent/self_modify_pipeline_test.exs`
- `mix test test/nex/agent/self_healing_router_test.exs`

## Stage 4

### 前置检查

- Stage 3 已完成。
- prompt/onboarding 只需要极小说明，不要把未来 11b+ 能力写成已存在。

### 这一步改哪里

- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/onboarding.ex`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/2026-04-24.md`

### 这一步要做

- 在 runtime guidance 中说明：
  - self-healing loop 会记录失败信号。
  - 11a 不自动修代码，不自动写 memory/skill。
  - owner run 仍负责 CODE deploy。
- 更新 progress。

### 实施注意事项

- 不要让 prompt 暗示已经有 reflective diagnosis worker。
- 不要让 agent 以为能量系统允许绕过用户或 owner deploy。

### 本 stage 验收

- 文档和 prompt 对 11a 能力描述一致。
- 没有夸大为完整自愈系统。

### 本 stage 验证

- `mix test test/nex/agent/context_builder_test.exs`

## Review Fail 条件

- 11a 中任何路径调用 LLM 做复盘。
- 11a 中任何路径写 MEMORY、创建 skill、生成 patch 或 deploy CODE。
- 事件存储落到安全禁区。
- hook 失败导致 Runner / self_update 主结果改变。
- 每次失败都产生大段 raw trace，导致 token 或磁盘成本不可控。
- Aggregator 输出只能人读，不能被后续机器消费。
- Router 没有能量检查。
- 接入范围超过三类事件，导致第一步不可控。
