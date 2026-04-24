# Phase 13A Minimal Control Plane Observability Cutover

## 当前状态

Phase 13 定义了 ControlPlane observability 的最终方向。13A 是第一步，不做全仓库 Logger 大迁移，也不上 SQLite / tracing / external telemetry。它只做能让 agent 立刻获得自查能力的最小可跑版本：

```text
ControlPlane observation store + log/metric/gauge API + observe tool
replace Phase 11A self-healing event/energy store
```

当前最直接的问题是：agent 看不到后台失败，只能依赖用户复制 `/tmp/nex-agent-gateway.log`。13A 必须先让 agent 能查结构化事实，而不是解析人类文本日志。

## 完成后必须达到的结果

1. 新增 `Nex.Agent.ControlPlane` namespace，包含最小 `Log` / `Metric` / `Gauge` / `Store` / `Budget` / `Redactor` / `Query`。
2. 新增单一 agent-facing tool：`observe`。
3. `SelfHealing.EventStore` 和 `SelfHealing.EnergyLedger` 不再是主链；Phase 11A 失败事件和 energy 迁到 ControlPlane。
4. Runner 和 SelfUpdate 现有 self-healing 事件测试改为查询 ControlPlane observation。
5. `observe summary/query/tail/metrics/incident` 能在临时 workspace 中运行并返回结构化结果。
6. Store 写入失败不破坏主业务，只返回 error 或 logger warning；但成功路径必须持久化 JSONL。
7. 不新增任何兼容别名、双写或旧 API 转发层。

## 开工前必须先看的代码路径

- `docs/dev/task-plan/phase13-control-plane-observability.md`
- `lib/nex/agent/self_healing/event_store.ex`
- `lib/nex/agent/self_healing/energy_ledger.ex`
- `lib/nex/agent/self_healing/aggregator.ex`
- `lib/nex/agent/self_healing/router.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/self_update/deployer.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/follow_up.ex`
- `lib/nex/agent/workspace.ex`
- `test/nex/agent/self_healing_event_store_test.exs`
- `test/nex/agent/self_healing_energy_ledger_test.exs`
- `test/nex/agent/self_healing_router_test.exs`
- `test/nex/agent/runner_evolution_test.exs`
- `test/nex/agent/self_modify_pipeline_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. 13A observation shape 使用 Phase 13 最小 envelope，不添加 `event` kind。

```elixir
%{
  "id" => String.t(),
  "timestamp" => String.t(),
  "kind" => "log" | "metric" | "gauge",
  "level" => "debug" | "info" | "warning" | "error" | "critical",
  "tag" => String.t(),
  "source" => %{
    "module" => String.t(),
    "function" => String.t() | nil,
    "file" => String.t(),
    "line" => pos_integer()
  },
  "context" => map(),
  "attrs" => map()
}
```

`context["workspace"]` 必须由 `opts[:workspace]` 规范化而来；缺省使用 `Nex.Agent.Workspace.root/0`。workspace 不允许出现在顶层字段或 `attrs`。`tag` 必须是点分字符串，不接受 atom tag。

2. 13A 只支持 JSONL backend。

```text
<workspace>/control_plane/observations/YYYY-MM-DD.jsonl
```

Query 必须通过 `ControlPlane.Query`，不要让 tool 直接读文件。

3. Gauge state path：

```text
<workspace>/control_plane/state/gauges.json
```

Gauge record 最小 shape：

```elixir
%{
  "name" => String.t(),
  "value" => term(),
  "updated_at" => String.t(),
  "context" => map(),
  "attrs" => map()
}
```

4. Budget state path：

```text
<workspace>/control_plane/state/budget.json
```

Budget shape 复用 Phase 13 contract。

5. `ControlPlane.Log.*` required API：

```elixir
ControlPlane.Log.debug(tag, attrs, opts)
ControlPlane.Log.info(tag, attrs, opts)
ControlPlane.Log.warning(tag, attrs, opts)
ControlPlane.Log.error(tag, attrs, opts)
```

13A 必须支持自动 source capture。允许 macro 包装 shared implementation。

6. `ControlPlane.Metric` required API：

```elixir
ControlPlane.Metric.count(name, value, attrs, opts)
ControlPlane.Metric.measure(name, value, attrs, opts)
```

13A 只写 observation，不做长期 rollup 表。Metric name 必须是字符串；metric observation 的 `level` 固定为 `"info"`，并且必须像 Log 一样捕获调用点 `source`。

7. `ControlPlane.Gauge` required API：

```elixir
ControlPlane.Gauge.set(name, value, attrs, opts)
ControlPlane.Gauge.current(name, opts)
```

Gauge name 必须是字符串；gauge observation 的 `level` 固定为 `"info"`，并且必须像 Log 一样捕获调用点 `source`。

8. `ControlPlane.Budget` required API：

```elixir
ControlPlane.Budget.current(opts)
ControlPlane.Budget.spend(action, cost, opts)
ControlPlane.Budget.mode(state)
```

旧 `SelfHealing.EnergyLedger` 删除或停止作为主入口；测试必须改查 `ControlPlane.Budget`。

9. `observe` tool surface：

```elixir
def name, do: "observe"
def category, do: :base
```

`observe` 必须出现在 `:all`、`:base`、`:follow_up`。13A 暂不放进 `:subagent`，除非后续 stage 明确 owner/subagent 观测边界。

10. `observe` actions：

```text
summary:
- recent error/warning observations
- current gauges
- budget state

query:
- filter by tag/level/run_id/session_key/query/since

tail:
- recent observations only, not raw files

metrics:
- metric/gauge observations and current gauge state

incident:
- correlate by run_id/session_key/tag/query
```

11. 13A 删除旧 tests 的旧真相源断言：

```text
EventStore.recent -> ControlPlane.Query.query
EnergyLedger.current -> ControlPlane.Budget.current
```

不保留 `SelfHealing.EventStore.recent` wrapper。

## 执行顺序 / stage 依赖

- Stage 1：新增 ControlPlane store/redactor/query/log API。
- Stage 2：新增 metric/gauge/budget。
- Stage 3：新增 observe tool 并接入 tool surface。
- Stage 4：替换 Phase 11A self-healing event/energy 主链和测试。
- Stage 5：更新 prompt/onboarding/progress。

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1、Stage 2。  
Stage 4 依赖 Stage 1、Stage 2。  
Stage 5 依赖 Stage 3、Stage 4。  

## Stage 1

### 前置检查

- 确认 repo 没有未清理的 `runtime_logs` 原型。
- 确认 store 不访问安全禁区。

### 这一步改哪里

- 新增 `lib/nex/agent/control_plane/store.ex`
- 新增 `lib/nex/agent/control_plane/redactor.ex`
- 新增 `lib/nex/agent/control_plane/query.ex`
- 新增 `lib/nex/agent/control_plane/log.ex`
- 新增 `test/nex/agent/control_plane_store_test.exs`
- 新增 `test/nex/agent/control_plane_log_test.exs`

### 这一步要做

- Store append/query JSONL observations。
- Redactor 在写入前处理敏感 key 和敏感文本模式。
- Query 支持 tag/level/run_id/session_key/since/query/limit。
- Log macro 捕获 source，并写 `kind="log"` observation。
- Log projection 可以调用 Logger，但 Logger 输出不是测试主断言。

### 实施注意事项

- Store append 失败返回 `{:error, reason}`。
- Query 坏行跳过。
- source file 使用 repo 相对路径或绝对路径要在测试中固定，不能随机混用。

### 本 stage 验收

- 单条 log observation 持久化到 workspace。
- 敏感字段不会进入 JSONL。
- Query 能按 tag/run_id 过滤。

### 本 stage 验证

- `mix test test/nex/agent/control_plane_store_test.exs`
- `mix test test/nex/agent/control_plane_log_test.exs`

## Stage 2

### 前置检查

- Stage 1 store/query/log 可用。

### 这一步改哪里

- 新增 `lib/nex/agent/control_plane/metric.ex`
- 新增 `lib/nex/agent/control_plane/gauge.ex`
- 新增 `lib/nex/agent/control_plane/budget.ex`
- 新增 `test/nex/agent/control_plane_metric_test.exs`
- 新增 `test/nex/agent/control_plane_gauge_test.exs`
- 新增 `test/nex/agent/control_plane_budget_test.exs`

### 这一步要做

- Metric 写 `kind="metric"` observation。
- Gauge 写 `kind="gauge"` observation，并更新 gauges.json。
- Budget 读取/初始化/spend/mode，使用 budget.json。
- Budget spend 写 metric/log observation，便于后续 observe。

### 实施注意事项

- 13A 不做长期 rollup，不维护第二套 metrics database。
- Budget 写失败不能破坏主业务，但必须返回可测试 error。

### 本 stage 验收

- Gauge current 可读。
- Budget mode 与 Phase 11A energy mode 行为一致。

### 本 stage 验证

- `mix test test/nex/agent/control_plane_metric_test.exs`
- `mix test test/nex/agent/control_plane_gauge_test.exs`
- `mix test test/nex/agent/control_plane_budget_test.exs`

## Stage 3

### 前置检查

- Stage 1/2 可用。
- 确认 follow-up surface 当前允许的只读工具列表。

### 这一步改哪里

- 新增 `lib/nex/agent/tool/observe.ex`
- 更新 `lib/nex/agent/tool/registry.ex`
- 更新 `lib/nex/agent/tool/tool_list.ex`
- 更新 `lib/nex/agent/follow_up.ex`
- 新增 `test/nex/agent/observe_tool_test.exs`
- 更新 `test/nex/agent/tool_alignment_test.exs`

### 这一步要做

- 实现 `summary/query/tail/metrics/incident`。
- `observe` 只通过 ControlPlane Query/Gauge/Budget，不读任意文件。
- `observe` 放入 `:base` 和 `:follow_up`。
- ToolList 标记 `observe` 为 `["tool"]`。

### 实施注意事项

- 不命名为 `runtime_logs`、`logs`、`events`，避免把工具心智绑回文件日志。
- 不接受 path 参数。

### 本 stage 验收

- follow-up agent 能调用 `observe`。
- `observe incident` 能按 run_id 聚合 error observation 和相关 metrics/gauges。

### 本 stage 验证

- `mix test test/nex/agent/observe_tool_test.exs`
- `mix test test/nex/agent/tool_alignment_test.exs`

## Stage 4

### 前置检查

- Stage 1/2/3 可用。
- 明确删除旧 API，不做兼容。

### 这一步改哪里

- 删除或重写 `lib/nex/agent/self_healing/event_store.ex`
- 删除或重写 `lib/nex/agent/self_healing/energy_ledger.ex`
- 更新 `lib/nex/agent/self_healing/router.ex`
- 更新 `lib/nex/agent/self_healing/aggregator.ex`
- 更新 `lib/nex/agent/runner.ex`
- 更新 `lib/nex/agent/self_update/deployer.ex`
- 更新 `test/nex/agent/self_healing_event_store_test.exs`
- 更新 `test/nex/agent/self_healing_energy_ledger_test.exs`
- 更新 `test/nex/agent/self_healing_router_test.exs`
- 更新 `test/nex/agent/runner_evolution_test.exs`
- 更新 `test/nex/agent/self_modify_pipeline_test.exs`

### 这一步要做

- 用 `ControlPlane.Log.error("runner.llm.call.failed", ...)`、`ControlPlane.Log.error("runner.tool.call.failed", ...)` 替换 Runner 旧 self-healing emit。
- 用 `ControlPlane.Log.error("self_update.deploy.failed", ...)` 替换 Deployer 旧 self-healing emit。
- Router 读取 ControlPlane observations 和 Budget。
- 删除 `SelfHealing.EventStore` / `EnergyLedger` 测试，或改名为 ControlPlane tests。

### 实施注意事项

- 不保留 `SelfHealing.EventStore.append/recent` wrapper。
- 不保留 `SelfHealing.EnergyLedger.current/spend` wrapper。
- 13A 只迁移 Phase 11A 已接入的三类失败：`runner.llm.call.failed`、`runner.tool.call.failed`、`self_update.deploy.failed`。
- Runner started/finished lifecycle、HTTP failure、tool task crash/timeout 的完整覆盖留给 13B。
- 编译错误驱动全部调用点迁移。

### 本 stage 验收

- Phase 11A 的三类失败仍能被记录和聚合，但事实来源变成 ControlPlane。
- 没有旧 self-healing store 文件写入。

### 本 stage 验证

- `mix test test/nex/agent/self_healing_router_test.exs`
- `mix test test/nex/agent/runner_evolution_test.exs`
- `mix test test/nex/agent/self_modify_pipeline_test.exs`

## Stage 5

### 前置检查

- Stage 4 已完成，旧 store/energy 主链已退出。

### 这一步改哪里

- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/onboarding.ex`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`

### 这一步要做

- Prompt 明确：
  - 遇到“报错了吗 / 卡住了吗 / 后台看到了什么”先用 `observe`。
  - ControlPlane 是自观测真相源。
  - Budget 只控制复盘/候选动作，不允许自动 deploy。
- 更新 progress 指向 Phase 13/13A。

### 实施注意事项

- 不宣传未实现的 Logger bridge / SQLite / full tracing。

### 本 stage 验收

- agent 视角知道如何无人查询自己的运行状态和失败证据。

### 本 stage 验证

- `mix test test/nex/agent/context_builder_test.exs`

## Review Fail 条件

- 13A 新增多个日志/事件查询工具。
- `observe` 可以读任意文件路径。
- 新旧 self-healing event store 双写。
- `SelfHealing.EnergyLedger` 仍是 budget 主入口。
- 结构化 observation 中 `context` / `attrs` 重复字段。
- Store 中出现未脱敏 secret/token/api key。
- Log API 不能自动记录代码行号。
- 第一阶段引入 SQLite、外部服务或长期进程作为硬依赖。
