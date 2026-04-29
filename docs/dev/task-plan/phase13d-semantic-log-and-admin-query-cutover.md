# Phase 13D Semantic Log And Admin Query Cutover

## 当前状态

Phase 13A/13B 建立了 ControlPlane observation substrate，并把 Runner / Tool.Registry / HTTP / SelfUpdate 的主要 lifecycle 观测接入。Phase 13C 计划继续把 RunControl / FollowUp / InboundWorker 的当前 run 和后台状态纳入 ControlPlane。

13D 是 ControlPlane 成为唯一机器真相源前的最后收口阶段，当前还有这些平行入口：

- `Nex.Agent.Observe.Compat.Audit` 写 workspace `audit/events.jsonl`，Admin 和 Evolution 仍可能把它当 recent event truth。
- `Nex.Agent.Observe.Compat.RequestTrace` 写 `audit/request_traces/*.jsonl`，Runner 仍有独立 trace append/read/list path。
- `Admin` 组合自己的 recent events / request trace view，没有保证和 `observe` 看到同一批 observations。
- 仓库里仍有大量语义 `Logger.*` 调用；其中一部分已经被 13B 的 ControlPlane observations 覆盖，但仍可能作为唯一机器证据存在。
- 13E 需要消费一个已经收口的 ControlPlane；如果 13D 不完成，Evolution 会面对 Audit、RequestTrace、Logger、ControlPlane 四套半真相源。

13D 的目标不是再加查询接口，而是删除平行观测主链：语义事实进入 `ControlPlane.Log/Metric/Gauge`，查询面统一读 `ControlPlane.Query`，人类日志只作为 projection 和 fallback。

## 完成后必须达到的结果

1. `Audit.append/3` 不再写独立 `audit/events.jsonl` 作为机器真相源；旧调用点迁移到 `ControlPlane.Log.*` 或删除。
2. `Audit.recent/1` 不再作为 Admin/Evolution/agent-facing 状态来源；如保留，只能是 ControlPlane query 的薄读视图。
3. `RequestTrace.append_event/2` / `read_trace/2` / `list_paths/1` 不再维护独立 request trace JSONL 主链；Runner trace facts 进入 ControlPlane observations。
4. Admin recent events、request trace、runtime incident/status 视图读 ControlPlane，与 `observe` 看到同一机器事实。
5. 仓库内剩余语义 `Logger.*` 调用要么迁移到 `ControlPlane.Log.*`，要么进入明确 allowlist。
6. Allowlist 只允许非机器真相源日志：ControlPlane projection/fallback、OTP/boot lifecycle、第三方 callback 边界、临时 debug 且不表达业务事实。
7. 13D 不新增第二个 agent-facing log/event/query tool；`observe` 仍是唯一 agent 可用观测查询工具。
8. 13E 可以只依赖 ControlPlane Query/Gauge/Budget，不需要读 Audit、RequestTrace 或 raw log。

## 开工前必须先看的代码路径

- `docs/dev/task-plan/phase13-control-plane-observability.md`
- `docs/dev/task-plan/phase13a-minimal-control-plane-observability-cutover.md`
- `docs/dev/task-plan/phase13b-control-plane-runtime-lifecycle-observability.md`
- `docs/dev/task-plan/phase13c-run-control-follow-up-observability.md`
- `lib/nex/agent/control_plane/log.ex`
- `lib/nex/agent/control_plane/query.ex`
- `lib/nex/agent/control_plane/store.ex`
- `lib/nex/agent/tool/observe.ex`
- `lib/nex/agent/audit.ex`
- `lib/nex/agent/request_trace.ex`
- `lib/nex/agent/admin.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/tasks.ex`
- `lib/nex/agent/cron.ex`
- `lib/nex/agent/executor.ex`
- `lib/nex/agent/knowledge.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/onboarding.ex`
- `test/nex/agent/admin_test.exs`
- `test/nex/agent/request_trace_test.exs`
- `test/nex/agent/observe_tool_test.exs`
- `test/nex/agent/tool_alignment_test.exs`
- `test/nex/agent/evolution_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. 13D 开工前置条件冻结：

```text
must be complete before 13D:
- Phase 13B review findings fixed:
  - gauge persisted state is redacted
  - failed tool evidence args_summary is redacted and bounded
  - tool.registry.execute.timeout has an owned emit path
- Phase 13C completed or explicitly split so RunControl/FollowUp/InboundWorker observations are already available
```

如果 13C 未完成，不进入 13D。Admin/status 收口必须能读当前 run/follow-up evidence。

2. Agent-facing query surface 冻结：

```text
observe
```

13D 不新增 `logs`、`events`、`trace`、`audit`、`admin_events` 等 agent-facing tool。Admin 内部可以有函数，但 agent 可用查询入口仍只有 `observe`。

3. Audit compatibility boundary 冻结：

```elixir
Audit.append(event :: String.t(), payload :: map(), opts :: keyword()) :: :ok
Audit.recent(opts :: keyword()) :: [map()]
```

如果保留这两个函数，只能作为 ControlPlane wrapper：

```text
Audit.append(event, payload, opts)
-> ControlPlane.Log.info(event, payload, opts)

Audit.recent(opts)
-> ControlPlane.Query.query(%{"tag_prefix" => nil, "limit" => limit}, opts)
```

不得继续写 `audit/events.jsonl`，不得双写 Audit file + ControlPlane。

4. RequestTrace compatibility boundary 冻结：

```elixir
RequestTrace.append_event(event :: map(), opts :: keyword()) ::
  {:ok, String.t()} | :ok | {:error, String.t()}

RequestTrace.list_paths(opts :: keyword()) :: [String.t()]
RequestTrace.read_trace(identifier :: String.t(), opts :: keyword()) :: [map()]
```

13D 可以删除调用点后删除这些 API；如果短期保留给内部测试或 admin 旧函数，只能读写 ControlPlane：

```text
append_event(%{run_id: run_id, event: event, ...}, opts)
-> ControlPlane.Log.info("request_trace.event.recorded", attrs, Keyword.put(opts, :run_id, run_id))

list_paths/read_trace
-> ControlPlane.Query.query by context["run_id"]
```

返回值不能承诺真实文件 path。若没有外部公开契约依赖，优先删除这些 API 和旧 tests。

5. Semantic Logger rule 冻结：

```text
business/runtime fact -> ControlPlane.Log/Metric/Gauge
human text output -> ControlPlane projection
fallback-only crash reporting -> direct Logger allowed
```

Direct `Logger.*` allowlist only includes：

```text
lib/nex/agent/control_plane/log.ex projection
lib/nex/agent/control_plane/*.ex store/projection failure fallback
application boot or OTP supervisor lifecycle that cannot resolve workspace
third-party callback boundary before ControlPlane context exists
temporary debug with no business fact and no machine-consumed state
tests that assert projection text only
```

Any direct `Logger.*` carrying run_id/tool/provider/error/status/duration/request/trace/user-visible lifecycle is a Review Fail unless it is also represented by a same-place ControlPlane observation and allowlisted as projection-only.

6. Admin event shape freezes to observation summary, not Audit event:

```elixir
%{
  "id" => String.t(),
  "timestamp" => String.t(),
  "level" => String.t(),
  "tag" => String.t(),
  "context" => map(),
  "attrs_summary" => map()
}
```

Admin must not expose old `%{"event" => ..., "payload" => ...}` as the canonical machine shape.

7. Request trace view freezes to run-scoped observations:

```elixir
%{
  "run_id" => String.t(),
  "observations" => [map()],
  "started_at" => String.t() | nil,
  "finished_at" => String.t() | nil,
  "levels" => map(),
  "tags" => map()
}
```

Trace entries are derived from `context["run_id"]` and observation tags, not from per-run JSONL files.

8. Existing raw files are not migrated in 13D:

```text
audit/events.jsonl
audit/request_traces/*.jsonl
```

13D stops future writes and code reads. It does not need to import historical raw files into ControlPlane.

## 执行顺序 / stage 依赖

- Stage 0：preflight，确认 13B findings 和 13C 已完成，并建立 Logger/Audit/RequestTrace inventory。
- Stage 1：补足 ControlPlane Query/Admin 所需的只读形状。
- Stage 2：Audit cutover，删除独立 audit file 主链。
- Stage 3：RequestTrace cutover，删除独立 request trace file 主链。
- Stage 4：Admin/query/status recent events 统一读 ControlPlane。
- Stage 5：全仓 semantic `Logger.*` migration 和 allowlist 测试。
- Stage 6：Prompt/onboarding/docs/progress 收尾，解锁 13E。

Stage 1 依赖 Stage 0。  
Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1。  
Stage 4 依赖 Stage 2、Stage 3。  
Stage 5 依赖 Stage 2、Stage 3。  
Stage 6 依赖 Stage 4、Stage 5。  

## Stage 0

### 前置检查

- Phase 13B review findings 已修复并有 focused tests。
- Phase 13C 已完成，RunControl / FollowUp / InboundWorker 观测已进入 ControlPlane。

### 这一步改哪里

- `docs/dev/task-plan/phase13d-semantic-log-and-admin-query-cutover.md`
- `lib/nex/agent/audit.ex`
- `lib/nex/agent/request_trace.ex`
- `lib/nex/agent/admin.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/**/*.ex`

### 这一步要做

- 用 `rg "Logger\\.|Audit\\.|RequestTrace\\." lib test` 建立迁移清单。
- 将每个调用点分类：
  - migrate to ControlPlane
  - delete because duplicate
  - allowlist as projection/fallback
- 确认没有代码读取 `audit/events.jsonl` 或 `audit/request_traces/*.jsonl` 作为机器真相源。

### 实施注意事项

- Inventory 是执行辅助，不需要新增长期配置文件。
- 不为了中间编译保留双写。

### 本 stage 验收

- reviewer 能从 diff 看出 Audit/RequestTrace/Logger 调用点的处理策略。
- 没有进入 13D 时顺手实现 13E 行为。

### 本 stage 验证

- `rg -n "Logger\\.|Audit\\.|RequestTrace\\." lib test`

## Stage 1

### 前置检查

- Stage 0 inventory 完成。
- `ControlPlane.Query` 当前 API 已确认。

### 这一步改哪里

- `lib/nex/agent/control_plane/query.ex`
- `lib/nex/agent/admin.ex`
- `test/nex/agent/control_plane_store_test.exs`
- `test/nex/agent/observe_tool_test.exs`
- `test/nex/agent/admin_test.exs`

### 这一步要做

- 如现有 Query 不足，补最小只读能力：
  - tag exact / tag prefix
  - level filter
  - run_id/session_key/context filter
  - since/limit
  - recent incident summary
- 新增 helper 只返回 bounded/redacted observation summary。
- Admin 只能调用 Query/helper，不直接读 Store 文件。

### 实施注意事项

- 不让 Query 接受任意 path。
- 不把 full attrs 原样暴露给 Admin/observe。
- 不新增第二套 Admin event schema。

### 本 stage 验收

- Query 能支撑 Audit.recent replacement、request trace run view、Admin recent events。
- Redaction/bounds 在 Query 返回侧仍成立。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/control_plane_store_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/observe_tool_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/admin_test.exs`

## Stage 2

### 前置检查

- Stage 1 Query helper 可用。
- 已列出 `Audit.append/3` 和 `Audit.recent/1` 调用点。

### 这一步改哪里

- `lib/nex/agent/audit.ex`
- `lib/nex/agent/executor.ex`
- `lib/nex/agent/knowledge.ex`
- `lib/nex/agent/admin.ex`
- `lib/nex/agent/evolution.ex`
- `test/nex/agent/admin_test.exs`
- `test/nex/agent/evolution_test.exs`

### 这一步要做

- 将 `Audit.append/3` 调用点迁移为 `ControlPlane.Log.*`。
- 对 `executor.dispatch`、`knowledge.capture`、`knowledge.promote` 等旧 audit event 冻结点分 tag：

```text
executor.dispatch.recorded
knowledge.capture.recorded
knowledge.promote.recorded
```

- 删除 `Audit.recent/1` 的文件读取语义，或删除 `Audit` 模块和测试调用点。
- `Admin.publish_audit_entry/1` 若保留，改为发布 ControlPlane observation summary。

### 实施注意事项

- 不保留 `Audit.append -> file write -> Admin publish` 旧链路。
- 如果保留 `Audit.append/3` 函数给内部 callers 过渡，同一 stage 内必须迁完调用点，最终没有生产代码调用它。

### 本 stage 验收

- 新事件能从 `ControlPlane.Query` 查到。
- 旧 `audit/events.jsonl` 不再被写入或读取。
- Evolution tests 不再通过 `Audit.append("evolution.*")` 构造机器事实。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/admin_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/evolution_test.exs`

## Stage 3

### 前置检查

- Stage 1 Query helper 可用。
- 已列出 `RequestTrace.append_event/2`、`read_trace/2`、`list_paths/1` 调用点。

### 这一步改哪里

- `lib/nex/agent/request_trace.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/admin.ex`
- `test/nex/agent/request_trace_test.exs`
- `test/nex/agent/admin_test.exs`
- `test/nex/agent/runner_evolution_test.exs`

### 这一步要做

- Runner 不再写独立 request trace JSONL。
- Run-scoped trace facts 通过既有 `runner.*`、`tool.*`、`http.*`、`run.owner.*` observations 表达。
- 如需保留 `RequestTrace.read_trace/2`，改为 `ControlPlane.Query.query(run_id: ...)` 的 derived view。
- 删除 `trace_path/2` 文件路径 contract，除非已确认它是外部公开 contract；测试不得依赖文件存在。

### 实施注意事项

- 不把 ControlPlane observation 再复制成 request trace 文件。
- 不把 request body/full prompt/full response 塞入 trace attrs。
- `request_trace.enabled` 配置不再控制机器真相源是否写入；最多控制 Admin 是否展示 derived trace view。

### 本 stage 验收

- Request trace tests 断言 ControlPlane-derived run trace。
- Runner lifecycle observations 足以重建 run trace。
- 没有新写 `audit/request_traces/*.jsonl`。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/request_trace_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/runner_evolution_test.exs`

## Stage 4

### 前置检查

- Stage 2/3 通过。
- Admin 当前使用的 recent events / trace view 已定位。

### 这一步改哪里

- `lib/nex/agent/admin.ex`
- `lib/nex/agent/admin/event.ex`
- `lib/nex/agent/tool/observe.ex`
- `test/nex/agent/admin_test.exs`
- `test/nex/agent/observe_tool_test.exs`

### 这一步要做

- Admin recent events 改读 ControlPlane observation summary。
- Admin request trace/status/incident 视图改为 Query-derived。
- 确保 Admin 和 observe 对同一 workspace/run_id/tag 返回一致 facts。
- 删除旧 audit event publish shape，或改成 ControlPlane observation summary shape。

### 实施注意事项

- Admin 不直接 `File.read` ControlPlane JSONL；统一走 Query。
- Admin 不暴露比 observe 更多的敏感字段。
- 不新增独立 Admin cache 作为状态源。

### 本 stage 验收

- Admin recent events 与 `observe tail/query` 可对齐到同一 observation ids。
- Admin request trace 与 `observe query run_id=...` 可对齐。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/admin_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/observe_tool_test.exs`

## Stage 5

### 前置检查

- Stage 2/3 已迁掉 Audit/RequestTrace 主链。
- ControlPlane Log projection 已覆盖 redaction。

### 这一步改哪里

- `lib/nex/agent/**/*.ex`
- `test/nex/agent/tool_alignment_test.exs`
- 可新增 `test/nex/agent/control_plane_logger_cutover_test.exs`

### 这一步要做

- 迁移剩余语义 `Logger.*` 调用到 `ControlPlane.Log.*`。
- 对允许直写 Logger 的调用点加最小注释或 centralized allowlist test。
- 补测试扫描生产代码里的 `Logger.`：

```elixir
allowed_logger_files = [
  "lib/nex/agent/control_plane/log.ex",
  "lib/nex/agent/control_plane/store.ex"
]
```

测试必须检查新增 direct Logger 不会悄悄绕过 ControlPlane。

### 实施注意事项

- 不机械替换第三方/OTP fallback 日志；先判断是否机器事实。
- 对没有 workspace/run context 的 boot 日志，可以保留 direct Logger，但不得被 Admin/Evolution 当事实读取。
- 不在每个模块发明自己的 redaction helper；统一走 ControlPlane。

### 本 stage 验收

- `rg "Logger\\." lib/nex/agent` 的剩余结果全部在 allowlist 内。
- 业务语义日志都可通过 ControlPlane 查询。
- 新增测试能阻止未来新增未审计 semantic Logger。

### 本 stage 验证

- `rg -n "Logger\\." lib/nex/agent`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/control_plane_logger_cutover_test.exs`

## Stage 6

### 前置检查

- Stage 1-5 focused tests 通过。
- `rg "Audit\\.|RequestTrace\\.|Logger\\." lib test` 剩余项已解释。

### 这一步改哪里

- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/onboarding.ex`
- `docs/dev/task-plan/phase13-control-plane-observability.md`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`
- `test/nex/agent/context_builder_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

### 这一步要做

- Prompt/onboarding 删除 Audit/RequestTrace/private log 作为 agent 可查真相源的描述。
- 文档声明 13D 完成后，13E 可以开始。
- CURRENT 记录剩余 direct Logger allowlist 和验证命令。

### 实施注意事项

- 不把 `/tmp/nex-agent-gateway.log` 写进 agent guidance。
- 不承诺历史 Audit/RequestTrace 文件迁移。

### 本 stage 验收

- 文案只指向 `observe` 和 ControlPlane。
- 13E preflight 可判断 13D 已完成。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/context_builder_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs`

## Review Fail 条件

- 13B P1 findings 未修复就进入 13D。
- 13C 未完成且 Admin/status 仍无法查询 current run/follow-up evidence。
- `Audit.append/3` 仍写 `audit/events.jsonl`。
- `Audit.recent/1`、Admin 或 Evolution 仍读 Audit 私有文件作为机器真相源。
- `RequestTrace.append_event/2` 仍写 `audit/request_traces/*.jsonl`。
- `RequestTrace.read_trace/2`、Admin 或 Runner tests 仍依赖 request trace 文件路径。
- 新增第二个 agent-facing log/event/trace query tool。
- Admin recent events 与 `observe` 返回不同事实源。
- Direct `Logger.*` 承载语义事实但没有 ControlPlane observation 或 allowlist。
- Logger allowlist 没有测试保护，导致后续新增 direct Logger 无法被发现。
- Query/Admin/observe 返回 full prompt、full response、full tool args、headers、body、patch content 或 secret 明文。
- 13E 仍需要 Audit/RequestTrace/raw log 才能运行。
