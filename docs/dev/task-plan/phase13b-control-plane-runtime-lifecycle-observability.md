# Phase 13B Control Plane Runtime Lifecycle Observability

## 当前状态

Phase 13A 已经把 Phase 11A 的三类 self-healing failure 和 energy 主链切到 ControlPlane：

```text
runner.llm.call.failed
runner.tool.call.failed
self_update.deploy.failed
```

但 13A 只覆盖最小失败信号。当前 runtime 仍有几类 agent 自查时看不到或看不完整的事实：

- Runner run / LLM call / tool batch lifecycle 主要还是 `Logger.*` 文本输出。
- `Tool.Registry.execute/3` 内部 task crash、timeout、cancel 的生命周期没有进入统一 observation。
- `Nex.Agent.Interface.HTTP.run_request/3` 会把内部 opts 直接传给 `Req`，例如 `:cancel_ref`，导致后台 task crash 只进入人类日志。
- HTTP failure / timeout / cancellation 没有成为 agent 可查询的结构化事实。
- SelfUpdate deploy 只有失败 observation，缺少 started/finished lifecycle，无法从 ControlPlane 还原一次 deploy 的闭环。

13B 的目标不是全仓库 Logger 清零，而是把 runtime 主链上会影响 agent 自查和自进化决策的生命周期事实迁到 ControlPlane。

## 完成后必须达到的结果

1. Runner 的 run / LLM call / tool batch / tool call 主生命周期写入 ControlPlane observation。
2. Tool.Registry 的 deterministic execution 边界写入 ControlPlane observation，task crash/timeout/cancel 必须可查。
3. HTTP request started/finished/failed/timeout/cancelled 写入 ControlPlane observation。
4. `Nex.Agent.Interface.HTTP` 内部 opts 不再泄漏给 `Req`，尤其 `:cancel_ref` 不允许进入 `Req.get/2` / `Req.post/2`。
5. HTTP task exception 不只进入 `/tmp/nex-agent-gateway.log`，必须转换成结构化返回并写 `http.request.failed`。
6. SelfUpdate deploy started/finished/failed 形成同一 run/deploy context 下的完整链路。
7. 13B 触碰范围内的语义 `Logger.*` 不再作为机器真相源；人类日志只来自 ControlPlane projection 或底层兜底 warning。
8. Tests 直接查询 ControlPlane observations，不解析 Logger 文本，不读 `/tmp/nex-agent-gateway.log`。

## 开工前必须先看的代码路径

- `docs/dev/task-plan/phase13-control-plane-observability.md`
- `docs/dev/task-plan/phase13a-minimal-control-plane-observability-cutover.md`
- `lib/nex/agent/control_plane/store.ex`
- `lib/nex/agent/control_plane/log.ex`
- `lib/nex/agent/control_plane/metric.ex`
- `lib/nex/agent/control_plane/gauge.ex`
- `lib/nex/agent/control_plane/query.ex`
- `lib/nex/agent/tool/observe.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/http.ex`
- `lib/nex/agent/self_update/deployer.ex`
- `test/nex/agent/control_plane_store_test.exs`
- `test/nex/agent/control_plane_log_test.exs`
- `test/nex/agent/control_plane_gauge_test.exs`
- `test/nex/agent/observe_tool_test.exs`
- `test/nex/agent/runner_evolution_test.exs`
- `test/nex/agent/http_test.exs`
- `test/nex/agent/self_modify_pipeline_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. 13B 开工前置条件冻结：

```text
13A redaction/context review findings must be fixed first:
- ControlPlane.Log projection uses redacted Store observation, not original attrs
- ControlPlane.Gauge state is redacted before gauges.json persist
- Store normalization removes context identity keys from attrs
```

如果任一前置条件不成立，先修 13A，不进入 13B lifecycle 迁移。

2. 13B 新增/补齐的 tag contract 冻结为点分字符串：

```text
runner.run.started
runner.run.finished
runner.run.failed

runner.llm.call.started
runner.llm.call.finished
runner.llm.call.failed

runner.tool.batch.started
runner.tool.batch.finished

runner.tool.call.started
runner.tool.call.finished
runner.tool.call.failed
runner.tool.task.exited
runner.tool.task.timeout
runner.tool.task.cancelled

tool.registry.execute.started
tool.registry.execute.finished
tool.registry.execute.failed
tool.registry.execute.timeout
tool.registry.execute.cancelled

http.request.started
http.request.finished
http.request.failed
http.request.timeout
http.request.cancelled

self_update.deploy.started
self_update.deploy.finished
self_update.deploy.failed
```

不得使用 atom tag。不得用 Logger 文案生成 tag。

3. Runner context contract：

```elixir
%{
  optional(:workspace) => String.t(),
  optional(:run_id) => String.t(),
  optional(:session_key) => String.t(),
  optional(:channel) => String.t(),
  optional(:chat_id) => String.t(),
  optional(:cancel_ref) => reference()
}
```

写入 ControlPlane 时只允许关联身份进入 `context`；`:cancel_ref` 不写入 context 或 attrs。

4. Runner attrs contract：

```elixir
%{
  optional("provider") => String.t(),
  optional("model") => String.t(),
  optional("iteration") => non_neg_integer(),
  optional("max_iterations") => pos_integer(),
  optional("duration_ms") => non_neg_integer(),
  optional("tool_call_count") => non_neg_integer(),
  optional("finish_reason") => String.t(),
  optional("result_status") => "ok" | "error" | "cancelled" | "timeout",
  optional("reason_type") => String.t(),
  optional("error_summary") => String.t()
}
```

`error_summary` 最长 1000 chars。不得存完整 prompt、完整 response、完整 conversation messages。

5. Tool call attrs contract：

```elixir
%{
  "tool_name" => String.t(),
  optional("tool_call_id") => String.t(),
  optional("duration_ms") => non_neg_integer(),
  optional("result_status") => "ok" | "error" | "cancelled" | "timeout",
  optional("reason_type") => String.t(),
  optional("error_summary") => String.t(),
  optional("args_summary") => String.t()
}
```

`args_summary` 最长 1000 chars，必须经过 redaction；不得存完整 raw args。

6. HTTP attrs contract：

```elixir
%{
  "method" => "get" | "post" | "put" | "patch" | "delete",
  optional("scheme") => String.t(),
  optional("host") => String.t(),
  optional("path") => String.t(),
  optional("status") => integer(),
  optional("duration_ms") => non_neg_integer(),
  optional("reason_type") => String.t(),
  optional("retryable") => boolean(),
  optional("cancelled") => boolean()
}
```

HTTP attrs 不存 query string、headers、body、authorization、cookie 或原始 URL。确需定位 URL 时只存 scheme/host/path。

7. HTTP request API 内部 opts contract：

```elixir
internal_opts = [
  :cancel_ref,
  :observe_context,
  :observe_attrs
]
```

`Nex.Agent.Interface.HTTP` 必须在调用 `Req` 前剥离内部 opts。`Req` 只能收到 Req 支持的 options。

8. HTTP task exception contract：

```elixir
{:error, {:exception, class :: String.t(), message :: String.t()}}
```

或等价可模式匹配结构。异常不得只表现为 linked task exit。调用方仍可得到原有 `{:error, reason}` 语义。

9. SelfUpdate attrs contract：

```elixir
%{
  "phase" => "self_update.deploy",
  optional("release_id") => String.t(),
  optional("duration_ms") => non_neg_integer(),
  optional("result_status") => "ok" | "failed",
  optional("runtime_restored") => String.t(),
  optional("rolled_back") => boolean(),
  optional("changed_files") => [String.t()],
  optional("reason_type") => String.t(),
  optional("error_summary") => String.t()
}
```

`changed_files` 只能是 repo-relative path，不存 patch 内容。

10. 失败去重 contract：

```text
same layer + same boundary + same failed operation => one failed observation
different layer boundaries may both emit if correlated by run_id/session/tool_call_id
```

例如 tool module crash 可以同时有：

```text
tool.registry.execute.failed
runner.tool.call.failed
```

但 Runner 同一 tool call 不得重复写两个 `runner.tool.call.failed`。

## 执行顺序 / stage 依赖

- Stage 0：验证 13A redaction/context 底座。
- Stage 1：迁移 Runner run / LLM lifecycle。
- Stage 2：迁移 Runner tool batch / tool call lifecycle。
- Stage 3：迁移 Tool.Registry execution lifecycle。
- Stage 4：迁移 HTTP request lifecycle，并修复 internal opts 泄漏。
- Stage 5：补齐 SelfUpdate deploy lifecycle。
- Stage 6：更新 prompt/docs/progress 与验收组合。

Stage 1 依赖 Stage 0。  
Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 2。  
Stage 4 依赖 Stage 0。  
Stage 5 依赖 Stage 0。  
Stage 6 依赖 Stage 1、Stage 2、Stage 3、Stage 4、Stage 5。  

## Stage 0

### 前置检查

- 13A 文件已存在，且 `observe` 可在临时 workspace 查询。
- `SelfHealing.EventStore` / `SelfHealing.EnergyLedger` 已删除或不再作为主入口。

### 这一步改哪里

- `lib/nex/agent/control_plane/log.ex`
- `lib/nex/agent/control_plane/gauge.ex`
- `lib/nex/agent/control_plane/store.ex`
- `test/nex/agent/control_plane_log_test.exs`
- `test/nex/agent/control_plane_gauge_test.exs`
- `test/nex/agent/control_plane_store_test.exs`

### 这一步要做

- 确认 Log projection 使用已脱敏 observation。
- 确认 Gauge state 在 persist 前已经脱敏。
- 确认 Store normalization 会从 attrs 删除 workspace/run/session/channel/chat/tool_call/trace identity。
- 如果上述任一不成立，先补测试并修复。

### 实施注意事项

- 不把 13A review finding 推迟到后续 stage。
- 不新增兼容 wrapper 或第二套 redaction。

### 本 stage 验收

- JSONL、gauges.json、Logger projection 都不包含敏感明文。
- `attrs` 不重复 context identity。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/control_plane_log_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/control_plane_gauge_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/control_plane_store_test.exs`

## Stage 1

### 前置检查

- Stage 0 通过。
- Runner 当前 13A failure emit helper 已读懂，避免重复写失败事件。

### 这一步改哪里

- `lib/nex/agent/runner.ex`
- `test/nex/agent/runner_evolution_test.exs`
- 新增 `test/nex/agent/runner_control_plane_lifecycle_test.exs`

### 这一步要做

- 在 owner run 开始、正常结束、失败结束时写 `runner.run.*`。
- 在每次 LLM call dispatch 前写 `runner.llm.call.started`。
- 在 LLM call 返回成功后写 `runner.llm.call.finished`，包含 duration、finish_reason、tool_call_count。
- 在 LLM call exception / error tuple / error finish_reason 时写且只写一次 `runner.llm.call.failed`。
- 把同一语义的 `Logger.info/error` 改为 ControlPlane Log；只保留底层调试或 ControlPlane 写入失败兜底 warning。

### 实施注意事项

- 不记录完整 prompt/messages/content。
- 不把 `cancel_ref` 写入 observation。
- `runner.llm.call.failed` 与 13A router 消费的 tag 保持同一个字符串。

### 本 stage 验收

- 一次 successful run 可以查询到 `runner.run.started`、`runner.llm.call.started`、`runner.llm.call.finished`、`runner.run.finished`。
- 一次 LLM failure 可以查询到 `runner.llm.call.failed`，并且 self-healing router 仍能消费。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/runner_control_plane_lifecycle_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/runner_evolution_test.exs`

## Stage 2

### 前置检查

- Stage 1 通过。
- Tool execution cancellation path 和 timeout path 已读懂。

### 这一步改哪里

- `lib/nex/agent/runner.ex`
- `test/nex/agent/runner_evolution_test.exs`
- `test/nex/agent/runner_control_plane_lifecycle_test.exs`

### 这一步要做

- 在 Runner 收到 tool calls 时写 `runner.tool.batch.started`。
- 在 tool batch 全部完成或因 cancel/timeout 结束时写 `runner.tool.batch.finished`。
- 每个 tool call dispatch 前写 `runner.tool.call.started`。
- 每个 tool call 成功返回后写 `runner.tool.call.finished`。
- tool result 为 error、task exit、timeout、cancel 时写对应 failure/exit/timeout/cancelled observation。
- 保证同一 failed tool call 对 `runner.tool.call.failed` 只写一次。

### 实施注意事项

- `args_summary` 必须限长和脱敏。
- 不把 tool 的完整 raw args、完整 stdout、完整 patch 内容存进 attrs。
- batch observation 不替代 per-tool observation。

### 本 stage 验收

- `observe incident` 通过 run_id 可以看到 tool batch 和具体 tool call 的 started/finished/failed 链路。
- tool task exit 不再只出现在 Logger 文本。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/runner_control_plane_lifecycle_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/runner_evolution_test.exs`

## Stage 3

### 前置检查

- Stage 2 通过。
- 确认 Tool.Registry 是 deterministic tool execution 边界，不把 channel 或 Runner 私有协议写入 Registry。

### 这一步改哪里

- `lib/nex/agent/tool/registry.ex`
- 新增 `test/nex/agent/tool_registry_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

### 这一步要做

- `Tool.Registry.execute/3` 开始执行时写 `tool.registry.execute.started`。
- 正常返回时写 `tool.registry.execute.finished`。
- tool module exception / throw / exit 写 `tool.registry.execute.failed`。
- timeout / cancellation 写 `tool.registry.execute.timeout` 或 `tool.registry.execute.cancelled`。
- Registry 只记录 deterministic execution 层事实；Runner 仍负责 owner run/tool call 层事实。

### 实施注意事项

- 不把 module discovery / hot-swap 管理日志全部纳入 13B；13B 只迁 execution lifecycle。
- Registry 不读取 workspace config；workspace/context 从 opts 传入。
- 不新增 Registry 私有 event store。

### 本 stage 验收

- 直接调用 `Tool.Registry.execute/3` 的成功、失败、timeout/cancel tests 可以查询 ControlPlane observation。
- Runner tool failure 与 Registry execution failure 通过同一个 tool_call_id/run_id 关联。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_registry_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs`

## Stage 4

### 前置检查

- Stage 0 通过。
- 已读 `Nex.Agent.Interface.HTTP.run_request/3` 和所有调用方，确认哪些 opts 是 Req opts，哪些是 Nex internal opts。

### 这一步改哪里

- `lib/nex/agent/http.ex`
- `test/nex/agent/http_test.exs`
- `test/nex/agent/web_fetch_tool_test.exs`
- `test/nex/agent/observe_tool_test.exs`

### 这一步要做

- 在 request 开始时写 `http.request.started`。
- 请求成功返回时写 `http.request.finished`，包含 method、scheme、host、path、status、duration_ms。
- request task exception 转为 `{:error, {:exception, class, message}}` 或等价结构，并写 `http.request.failed`。
- timeout 写 `http.request.timeout` 并返回可操作 error。
- cancel 写 `http.request.cancelled` 并返回可操作 error。
- 在调用 `Req` 前剥离 `:cancel_ref`、`:observe_context`、`:observe_attrs` 等内部 opts。

### 实施注意事项

- 不直接裸读配置文件或安全禁区。
- 不记录 request/response body、headers、query string。
- HTTP observation 写入失败不能让原请求成功路径失败，但必须有 focused test 覆盖失败返回不崩溃。

### 本 stage 验收

- 复现 `cancel_ref` 场景时，不再出现 `ArgumentError unknown option :cancel_ref`。
- 如果底层 Req 抛异常，agent 可通过 `observe incident` 查到 `http.request.failed`。
- timeout/cancel 不只依赖 Logger 文本。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/http_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/observe_tool_test.exs`

## Stage 5

### 前置检查

- Stage 0 通过。
- SelfUpdate deploy 当前失败 observation 已读懂，确认不重复写 failed。

### 这一步改哪里

- `lib/nex/agent/self_update/deployer.ex`
- `test/nex/agent/self_modify_pipeline_test.exs`

### 这一步要做

- deploy 开始时写 `self_update.deploy.started`。
- deploy 成功时写 `self_update.deploy.finished`。
- deploy 失败继续写 `self_update.deploy.failed`，并与 started 使用同一 release/deploy context。
- deploy result attrs 只放 release_id、duration、status、runtime_restored、rolled_back、changed_files、error_summary。

### 实施注意事项

- 不记录 patch 内容。
- 不改变 deploy 原有返回语义。
- ControlPlane 写入失败只能作为 deploy metadata warning，不把成功 deploy 改成失败。

### 本 stage 验收

- 一次成功 deploy 可以通过 release_id 查到 started/finished。
- 一次失败 deploy 可以通过 release_id 查到 started/failed，并被 router/budget 继续消费。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/self_modify_pipeline_test.exs`

## Stage 6

### 前置检查

- Stage 1-5 focused tests 通过。

### 这一步改哪里

- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`
- `lib/nex/agent/onboarding.ex`
- 如需更新 prompt：对应 runtime prompt / ContextBuilder 文件

### 这一步要做

- 更新 progress，说明 13B 已覆盖 runtime lifecycle。
- 如 prompt/onboarding 仍暗示只能看三类 13A failure，改成说明可用 `observe` 查 run/LLM/tool/HTTP/self_update lifecycle。
- 保持 follow-up 只读 observe，不扩大工具 surface。

### 实施注意事项

- 不新增第二个 log/event 查询 tool。
- 不把 13C 的 RunControl gauge/current owner work 提前塞进 13B。

### 本 stage 验收

- 文档、prompt、tool surface 对 13B 能力描述一致。
- 13C 仍清楚保留 RunControl / FollowUp / InboundWorker 收口工作。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/context_builder_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs`

## Review Fail 条件

- 13A redaction/context findings 未修复就开始迁移 13B。
- 任一 13B tag 使用 atom 或非点分字符串。
- `:cancel_ref`、`:observe_context`、`:observe_attrs` 或其他 Nex internal opts 进入 `Req`。
- HTTP task crash 只进入 Logger，没有结构化 error 返回和 `http.request.failed`。
- Runner / Tool.Registry / HTTP / SelfUpdate 的主生命周期仍以语义 `Logger.*` 作为机器真相源。
- 同一层同一失败重复写多个同 tag failed observation。
- JSONL、gauges.json 或 Logger projection 出现 token、authorization、cookie、password、secret 等明文。
- observation attrs 存完整 prompt、完整 response、完整 tool args、headers、body、query string 或 patch 内容。
- `observe` 为了排查 HTTP/Runner 错误去读任意文件或 `/tmp/nex-agent-gateway.log`。
- Registry、HTTP 或 SelfUpdate 新增第二套私有 event/log store。
- 只测 happy path，没有覆盖 LLM failure、tool task exit/timeout、HTTP exception、HTTP cancel/timeout、deploy failure。
