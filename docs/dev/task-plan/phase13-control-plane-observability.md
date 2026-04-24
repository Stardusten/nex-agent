# Phase 13 Control Plane Observability

## 当前状态

Phase 11A 建了一个最小 self-healing event store，但它仍是局部系统：

- `SelfHealing.EventStore` / `Router` / `EnergyLedger` 只服务失败信号。
- `Logger.*` 文本日志仍是人工排查主入口，agent 自己不能稳定查询。
- `Audit`、`RequestTrace`、`Bus`、`RunControl`、self-healing events 各有自己的状态和记录格式。
- 后台 `Task` / HTTP / channel crash 可能只进入 `/tmp/nex-agent-gateway.log`，不会进入 agent 可查询的结构化事实。
- agent 遇到“刚才是不是报错了”只能看 run phase 和 partial output，无法无人执行地定位后台失败。

本 phase 目标不是再加一个 log tool，而是把 Nex 的运行时观测抽成一个 CODE 层控制平面：

```text
runtime code -> ControlPlane observation -> durable store -> human log projection
                                      -> metrics/gauge state
                                      -> observe tool
                                      -> evolution budget/router
```

## 完成后必须达到的结果

1. Nex 有一个统一 ControlPlane observability substrate，机器真相源是结构化 observation，不是文本 log。
2. agent 可通过单一 `observe` tool 查询最近运行事实、错误、指标、当前 run 状态和 incident evidence，不需要人把后台 log 复制给它。
3. 业务代码不再直接向 self-healing event store / energy ledger / request trace 这类平行系统写同类事实。
4. `ControlPlane.Log.*` 是语义日志 API；它同时写结构化 observation，并投影为人类可读 Logger 输出。
5. `ControlPlane.Metric` / `ControlPlane.Gauge` 是指标 API；energy/metabolism 从 self-healing 私有状态迁到 ControlPlane budget state。
6. `context` 和 `attrs` 边界清晰，不重复：
   - `context` 只放关联身份和执行边界
   - `attrs` 只放该条 observation 的业务参数
7. 新旧 observability API 不长期并存。每个迁移 stage 必须删除或替换同一能力的旧入口，不做双写兼容垫片。
8. 所有持久化都落在 workspace/repo 内，不访问安全禁区。

## 开工前必须先看的代码路径

- `docs/dev/task-plan/phase11-self-healing-driver.md`
- `docs/dev/task-plan/phase11a-minimal-self-healing-loop.md`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/http.ex`
- `lib/nex/agent/run_control.ex`
- `lib/nex/agent/follow_up.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/self_update/deployer.ex`
- `lib/nex/agent/self_healing/event_store.ex`
- `lib/nex/agent/self_healing/energy_ledger.ex`
- `lib/nex/agent/self_healing/router.ex`
- `lib/nex/agent/audit.ex`
- `lib/nex/agent/request_trace.ex`
- `lib/nex/agent/admin.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/onboarding.ex`
- `test/nex/agent/runner_evolution_test.exs`
- `test/nex/agent/self_healing_*_test.exs`
- `test/nex/agent/request_trace_test.exs`
- `test/nex/agent/run_control_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. 最小 observation envelope 冻结为：

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
  "context" => %{
    optional("workspace") => String.t(),
    optional("run_id") => String.t(),
    optional("session_key") => String.t(),
    optional("channel") => String.t(),
    optional("chat_id") => String.t(),
    optional("tool_call_id") => String.t(),
    optional("trace_id") => String.t()
  },
  "attrs" => map()
}
```

不引入单独 `event` kind。原 self-healing event 语义由 `kind="log"` + stable `tag` 表达。

2. `context` / `attrs` 边界冻结：

```text
context:
- 用于跨 observation 关联和查询过滤
- 只放 workspace/run/session/channel/chat/tool_call/trace 身份
- 不放 error reason、duration、tool args、provider、status
- `opts[:workspace]` 必须规范化进 `context["workspace"]`
- 缺省 workspace 使用 `Nex.Agent.Workspace.root/0`
- workspace 不允许放在顶层字段或 `attrs`

attrs:
- 用于描述这条 observation 发生了什么
- 放 duration_ms、tool_name、provider、status、reason、retryable、count、value 等业务参数
- 不重复 context 中的字段
```

3. tag 是稳定机器 contract。

```text
runner.llm.call.started
runner.llm.call.finished
runner.llm.call.failed
runner.tool.call.started
runner.tool.call.finished
runner.tool.call.failed
http.request.failed
self_update.deploy.failed
run.owner.started
run.owner.finished
run.owner.failed
```

tag 用点分层级，不从 Logger 文案中解析。

Log API 只接受点分字符串 tag。不得用 atom tag，也不得在不同调用点混用 `"runner.tool.call.failed"` 和 `:runner_tool_call_failed`。Metric/Gauge name 同样使用字符串。

4. ControlPlane public API 冻结为必要版本：

```elixir
ControlPlane.Log.debug(tag :: String.t(), attrs, opts)
ControlPlane.Log.info(tag :: String.t(), attrs, opts)
ControlPlane.Log.warning(tag :: String.t(), attrs, opts)
ControlPlane.Log.error(tag :: String.t(), attrs, opts)

ControlPlane.Metric.count(name :: String.t(), value, attrs, opts)
ControlPlane.Metric.measure(name :: String.t(), value, attrs, opts)

ControlPlane.Gauge.set(name :: String.t(), value, attrs, opts)
ControlPlane.Gauge.current(name :: String.t(), opts)
```

`Log.*` / `Metric.*` / `Gauge.*` 必须是 macro 或等价机制，自动记录调用点 `source`。Metric/Gauge observation 的 `level` 固定为 `"info"`，除非后续 phase 明确扩展 API。调用方只传 `tag/name`、`attrs` 和 context opts。

5. Store 路径冻结为 workspace 内：

```text
<workspace>/control_plane/observations/YYYY-MM-DD.jsonl
<workspace>/control_plane/state/gauges.json
<workspace>/control_plane/state/budget.json
```

不得使用 `~/.nex`。不得把 `/tmp/nex-agent-gateway.log` 当机器真相源。

6. Human log 是 projection，不是真相源。

```text
ControlPlane.Log.error("runner.tool.call.failed", attrs, opts)
-> append JSONL observation
-> Logger.error("[runner.tool.call.failed] ...")
```

业务模块不直接写 `Logger.*` 表达语义事实。底层第三方/OTP Logger 输出保留为外部兜底，不属于第一机器真相源。

7. Agent 查询工具只允许一个：

```text
observe
```

输入冻结为：

```elixir
%{
  "action" => "summary" | "query" | "tail" | "metrics" | "incident",
  optional("tag") => String.t(),
  optional("level") => String.t(),
  optional("run_id") => String.t(),
  optional("session_key") => String.t(),
  optional("query") => String.t(),
  optional("since") => String.t(),
  optional("limit") => pos_integer()
}
```

`observe` 只读 ControlPlane store / gauge state，不接受任意文件路径。

8. Redaction boundary 冻结：

```text
api_key
authorization
token
access_token
refresh_token
secret
password
cookie
```

这些 key 或文本模式在 store 和 projection 前都必须脱敏。测试必须覆盖 store 内容本身不含明文。

9. Budget / energy 属于 ControlPlane。

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

后续 Evolution / self-healing router 只能消费 ControlPlane budget，不维护私有 energy ledger。

10. 迁移原则冻结：

```text
same capability -> one API
no dual write
no compatibility shim
compile errors drive call-site migration
```

允许分 stage 迁移不同能力，但一个 stage 触碰的旧 API 必须在该 stage 内删除或停止作为主入口。

## 执行顺序 / stage 依赖

- Stage 13A：建立最小 ControlPlane substrate，并一次性替换 Phase 11A 三类失败 event/energy 主链。
- Stage 13B：迁移 Runner / Tool.Registry / HTTP / SelfUpdate 的完整语义 Logger 与 lifecycle 观测。
- Stage 13C：迁移 RunControl / FollowUp / InboundWorker，让 agent 可查当前 run、后台失败和 incident。
- Stage 13D：收口 Audit / RequestTrace 与 Admin 观测面，删除平行查询心智。
- Stage 13E：让 Evolution / higher-level self-healing aggregation 消费 ControlPlane observations 和 budget。

13B 依赖 13A。  
13C 依赖 13A。  
13D 依赖 13A、13B。  
13E 依赖 13A、13D。  

## Stage 13A

详见 [Phase 13A Minimal Control Plane Observability Cutover](./phase13a-minimal-control-plane-observability-cutover.md)。

## Stage 13B

详见 [Phase 13B Control Plane Runtime Lifecycle Observability](./phase13b-control-plane-runtime-lifecycle-observability.md)。

## Stage 13C

详见 [Phase 13C Run Control And Follow-Up Observability](./phase13c-run-control-follow-up-observability.md)。

## Stage 13D

详见 [Phase 13D Semantic Log And Admin Query Cutover](./phase13d-semantic-log-and-admin-query-cutover.md)。

## Stage 13E

详见 [Phase 13E Evolution Control Plane Consumption](./phase13e-evolution-control-plane-consumption.md)。

## Review Fail 条件

- 新增第二个 agent-facing log/event 查询 tool。
- `context` 和 `attrs` 存重复字段。
- 语义日志仍直接 `Logger.*`，没有经过 ControlPlane。
- 同一失败同时写旧 SelfHealing.EventStore 和新 ControlPlane store。
- Store 或 budget 落到 `~/.nex`。
- `observe` 能读任意路径。
- 敏感字段明文进入 JSONL。
- Evolution / self-healing 仍维护私有 energy ledger。
