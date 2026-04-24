# Phase 13C Run Control And Follow-Up Observability

## 当前状态

Phase 13A 建立了 ControlPlane observation store / gauge / budget / observe tool，并把 Phase 11A 的三类 self-healing failure 切到 ControlPlane。Phase 13B 继续把 Runner / Tool.Registry / HTTP / SelfUpdate 的 runtime lifecycle 写入 ControlPlane。

但用户真正问“刚才报错了吗 / 卡在哪里 / 后台看到了什么”时，当前主链仍有断点：

- `RunControl` 拥有当前 owner run 的 live volatile state，但不会把当前 phase/tool/queue/partial 投影到 ControlPlane gauge。
- `/status` 直接读 `RunControl.owner_snapshot/2`，follow-up prompt 也只携带文本 snapshot；两者还没有共同的 ControlPlane evidence 视图。
- `InboundWorker` 的 owner run dispatch、follow-up dispatch、queue、interrupt、task timeout/crash 仍主要靠内存状态和 Logger 文本。
- follow-up 虽然有 `observe` tool，但 prompt 没有硬性要求它在回答“报错了吗 / 卡住了吗 / 后台是什么”时先查询 ControlPlane。

13C 的目标是把“当前 run 状态”和“忙碌时的自查回答”收口到同一个控制平面读模型上：

```text
RunControl volatile owner state
  -> ControlPlane run.owner.current gauge
  -> /status deterministic status
  -> follow-up prompt + observe summary/incident
```

## 完成后必须达到的结果

1. `RunControl` owner lifecycle 写入 ControlPlane observations。
2. `RunControl` 每次 owner state 变化后投影 workspace 内 `run.owner.current` gauge。
3. `observe summary` 可以看到当前 workspace 的 active owner runs，包括 phase、tool、elapsed、queued、有限 tail。
4. `/status` 继续 deterministic，但必须使用 RunControl + ControlPlane recent evidence，而不是只输出孤立 snapshot。
5. follow-up prompt 明确要求：回答错误、卡住、后台状态、日志、incident 类问题前，先使用 `observe summary` 或 `observe incident`。
6. `InboundWorker` 的 owner dispatch / follow-up dispatch / queue / interrupt / task timeout/crash 写入 ControlPlane observation。
7. follow-up 工具面保持只读 + interrupt，不新增第二个 log/event 查询 tool。
8. Tests 覆盖 owner run 主成功路径、主失败路径、interrupt/cancel 路径、follow-up observe guidance、`/status` 与 observe evidence 对齐。

## 开工前必须先看的代码路径

- `docs/dev/task-plan/phase13-control-plane-observability.md`
- `docs/dev/task-plan/phase13a-minimal-control-plane-observability-cutover.md`
- `docs/dev/task-plan/phase13b-control-plane-runtime-lifecycle-observability.md`
- `lib/nex/agent/control_plane/gauge.ex`
- `lib/nex/agent/control_plane/query.ex`
- `lib/nex/agent/tool/observe.ex`
- `lib/nex/agent/run_control.ex`
- `lib/nex/agent/follow_up.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/tool/interrupt_session.ex`
- `test/nex/agent/run_control_test.exs`
- `test/nex/agent/inbound_worker_test.exs`
- `test/nex/agent/observe_tool_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. 13C 开工前置条件冻结：

```text
13B review findings must be fixed first:
- runner failed tool evidence args are redacted and bounded
- tool.registry.execute.timeout has an owned emit path and focused test
- gauge state redaction remains covered
```

如果任一前置条件不成立，先修 13A/13B，不进入 13C。

2. 13C 不新增 agent-facing tool。

```text
allowed query tool remains:
observe
```

不得新增 `logs`、`events`、`status_log`、`read_log` 之类第二查询入口。`/status` 是 deterministic command，不是新 tool。

3. RunControl observation tags 冻结为点分字符串：

```text
run.owner.started
run.owner.updated
run.owner.finished
run.owner.failed
run.owner.cancelled
run.owner.stale_result
```

`run.owner.updated` 用 attrs 区分 update type，不再为 phase/tool/queue/partial 各造一套 tag。

4. InboundWorker observation tags 冻结为点分字符串：

```text
inbound.message.received
inbound.owner.dispatch.started
inbound.owner.dispatch.finished
inbound.owner.dispatch.failed
inbound.owner.dispatch.timeout
inbound.follow_up.started
inbound.follow_up.finished
inbound.follow_up.failed
inbound.queue.changed
inbound.interrupt.requested
inbound.status.requested
```

5. `run.owner.current` gauge name 冻结：

```elixir
ControlPlane.Gauge.set(
  "run.owner.current",
  %{
    "owners" => [
      %{
        "run_id" => String.t(),
        "session_key" => String.t(),
        "channel" => String.t(),
        "chat_id" => String.t(),
        "status" => "running" | "cancelling",
        "phase" => "starting" | "llm" | "tool" | "streaming" | "finalizing" | "idle",
        "current_tool" => String.t() | nil,
        "elapsed_ms" => non_neg_integer(),
        "queued_count" => non_neg_integer(),
        "latest_assistant_partial_tail" => String.t(),
        "latest_tool_output_tail" => String.t(),
        "updated_at" => String.t()
      }
    ]
  },
  %{"source" => "run_control"},
  workspace: workspace
)
```

Gauge value is a workspace-level projection of all active owners in that workspace. Do not create dynamic gauge names per session.

6. Tail boundary 冻结：

```text
latest_assistant_partial_tail max 1000 chars
latest_tool_output_tail max 1000 chars
all tails pass ControlPlane.Redactor before Gauge.persist
```

Gauge tails are for status/debug context only. They must not store full prompt, full tool output, full LLM response, full file content, headers, body, or patch content.

7. RunControl remains the volatile owner state authority.

```text
RunControl state -> ControlPlane gauge projection
```

ControlPlane gauge is query projection, not a second scheduler. If gauge write fails, owner run behavior must continue.

8. `/status` output contract：

```text
Status line:
- idle, or current owner run status/phase/tool/elapsed/queued

Evidence line:
- recent warning/error count for current run/session
- latest error tag + short summary when present
```

`/status` must not read `/tmp/nex-agent-gateway.log` or arbitrary files. It reads `RunControl.owner_snapshot/2` and `ControlPlane.Query`.

9. Follow-up prompt contract：

```text
For questions about:
- error / failed / 报错
- stuck / 卡住
- backend / 后台
- logs / 日志
- status / 进度

the follow-up model must use observe summary or observe incident before answering,
unless the user only asks to stop/cancel and interrupt is the direct action.
```

The prompt must include `run_id`, `session_key`, `workspace`, and recommended observe filters. It must not include hidden raw logs.

10. Follow-up tool surface stays frozen:

```text
read-only tools + interrupt_session
observe remains available
self_update/apply_patch/bash/message stay unavailable to follow_up unless already frozen elsewhere
```

13C must not widen follow-up into an owner run.

## 执行顺序 / stage 依赖

- Stage 0：验证 13A/13B redaction 与 timeout 前置条件。
- Stage 1：RunControl owner lifecycle observations 与 gauge projection。
- Stage 2：InboundWorker owner/follow-up/queue/interrupt observations。
- Stage 3：`/status` 改读 RunControl + ControlPlane evidence。
- Stage 4：FollowUp prompt 收口到 observe-driven 自查。
- Stage 5：Docs/progress/onboarding 收尾。

Stage 1 依赖 Stage 0。  
Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1、Stage 2。  
Stage 4 依赖 Stage 1、Stage 2。  
Stage 5 依赖 Stage 3、Stage 4。  

## Stage 0

### 前置检查

- 13A ControlPlane store/query/gauge 可用。
- 13B runtime lifecycle focused tests 已通过。

### 这一步改哪里

- `lib/nex/agent/runner.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/control_plane/gauge.ex`
- `test/nex/agent/runner_evolution_test.exs`
- `test/nex/agent/tool_registry_test.exs`
- `test/nex/agent/control_plane_gauge_test.exs`

### 这一步要做

- 确认 failed tool evidence 不再使用未脱敏 `summarize_args/2`。
- 确认 Registry 有 owned timeout path，且写 `tool.registry.execute.timeout`。
- 确认 gauge state 持久化前脱敏。

### 实施注意事项

- 不把 13B review findings 推迟到 13C 后半段。
- 不为了通过测试删除 13B 冻结 tag。

### 本 stage 验收

- 13B review findings 全部有实现和 focused test。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/runner_evolution_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_registry_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/control_plane_gauge_test.exs`

## Stage 1

### 前置检查

- Stage 0 通过。
- 已确认 `RunControl` 是 owner run volatile state authority。

### 这一步改哪里

- `lib/nex/agent/run_control.ex`
- `test/nex/agent/run_control_test.exs`
- `test/nex/agent/observe_tool_test.exs`

### 这一步要做

- `start_owner/4` 成功后写 `run.owner.started`。
- `finish_owner/3` 成功后写 `run.owner.finished`，并刷新 `run.owner.current` gauge。
- `fail_owner/3` 成功后写 `run.owner.failed`，并刷新 gauge。
- `cancel_owner/4` 成功后写 `run.owner.cancelled`，并刷新 gauge。
- `append_tool_output/4`、`append_assistant_partial/3`、`set_phase/3`、`set_queued_count/3` 成功后写 `run.owner.updated`，并刷新 gauge。
- stale finish/fail/update 写 `run.owner.stale_result`，但不得恢复旧 run。

### 实施注意事项

- Gauge write failure 不影响 RunControl 返回。
- Gauge value 只包含 bounded/redacted tails。
- `cancel_ref` 不写入 observation 或 gauge。
- 不把 RunControl 变成持久 scheduler；ControlPlane 只是 projection。

### 本 stage 验收

- `observe summary` 在同一 workspace 中能看到 `run.owner.current` gauge。
- finish/fail/cancel 后 gauge 中该 owner 消失或 owners 为空。
- 多 session owner 在同一 workspace 下进入同一个 `run.owner.current` gauge 的 `owners` 列表。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/run_control_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/observe_tool_test.exs`

## Stage 2

### 前置检查

- Stage 1 通过。
- `InboundWorker` owner/follow-up/queue/interrupt 主路径已读懂。

### 这一步改哪里

- `lib/nex/agent/inbound_worker.ex`
- `test/nex/agent/inbound_worker_test.exs`

### 这一步要做

- 收到 `%Envelope{}` 后写 `inbound.message.received`。
- owner run dispatch 前写 `inbound.owner.dispatch.started`。
- owner run success/failure result 写 `inbound.owner.dispatch.finished` / `inbound.owner.dispatch.failed`。
- `check_timeout` killing owner task 时写 `inbound.owner.dispatch.timeout`。
- follow-up dispatch/result 写 `inbound.follow_up.started` / `finished` / `failed`。
- `/queue` enqueue/drop/drain 写 `inbound.queue.changed`。
- `/stop`、`interrupt_session` 统一写 `inbound.interrupt.requested`。

### 实施注意事项

- 不记录 inbound raw payload、full user text、full response body。
- `attrs["message_preview"]` 如需要，最多 200 chars 且 redacted。
- 不把 channel-specific Feishu/Discord payload 细节散到 ControlPlane attrs。
- Observation write failure 不影响 message handling。

### 本 stage 验收

- owner success、owner failure、task timeout/crash、follow-up success/failure、queue、interrupt 都能通过 ControlPlane query 找到结构化 observation。
- InboundWorker 不维护新的 event store。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/inbound_worker_test.exs`

## Stage 3

### 前置检查

- Stage 1、Stage 2 通过。
- `run.owner.current` gauge 能被 `observe summary` 返回。

### 这一步改哪里

- `lib/nex/agent/follow_up.ex`
- `lib/nex/agent/inbound_worker.ex`
- `test/nex/agent/inbound_worker_test.exs`

### 这一步要做

- `/status` 继续 deterministic。
- `/status` idle 时输出 idle，并可附最近 session warning/error 数量。
- `/status` busy 时输出 `FollowUp.render_status(run)`，并追加 current run/session 最近 warning/error summary。
- `/status` 每次调用写 `inbound.status.requested`。
- `/status` 使用 `ControlPlane.Query`，不调用 agent-facing `observe` tool，也不读 raw files。

### 实施注意事项

- `/status` 不触发 LLM。
- `/status` 不读取 `/tmp/nex-agent-gateway.log`。
- 输出中只展示短 summary，不回显完整 tool output/error body。

### 本 stage 验收

- `/status` 与 `observe summary` 对同一个 current owner run 给出一致 phase/tool/queued 信息。
- 有 recent failure 时，`/status` 能显示 latest tag 或 short error summary。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/inbound_worker_test.exs`

## Stage 4

### 前置检查

- Stage 1、Stage 2 通过。
- `observe` 在 `:follow_up` surface 中仍可用。

### 这一步改哪里

- `lib/nex/agent/follow_up.ex`
- `test/nex/agent/inbound_worker_test.exs`
- 新增 `test/nex/agent/follow_up_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

### 这一步要做

- Busy follow-up prompt 中加入 observe-driven 自查规则。
- Prompt 明确给出推荐 filters：
  - `observe summary`
  - `observe incident` with current `run_id`
  - `observe query` with `session_key`
- Prompt 明确禁止从 owner snapshot 推断“没有报错”；必须查 ControlPlane 后再说。
- Idle follow-up prompt 也说明可以用 `observe summary` 查最近 session/workspace evidence，但不得 invent active owner run。

### 实施注意事项

- 不扩大 follow-up tools。
- 不把 follow-up 变成 owner run。
- 不在 prompt 中包含 raw log 文件路径作为机器真相源。

### 本 stage 验收

- 用户问“报错了吗 / 卡在哪里 / 后台看到什么”时，follow-up prompt 会引导使用 `observe`。
- `:follow_up` tool surface 仍只有允许的 read-only tools + interrupt。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/inbound_worker_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/follow_up_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs`

## Stage 5

### 前置检查

- Stage 1-4 focused tests 通过。

### 这一步改哪里

- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`
- `lib/nex/agent/onboarding.ex`
- 如需更新 prompt：对应 runtime prompt / ContextBuilder 文件

### 这一步要做

- 更新 progress，说明 13C 已覆盖 RunControl / FollowUp / InboundWorker。
- Onboarding/prompt 中说明：忙碌时自查使用 `observe summary` / `observe incident`，`/status` 是 deterministic 快速视图。
- 保留 13D 范围：Audit / RequestTrace / Admin 后续再收口。

### 实施注意事项

- 不提前做 13D 的 Audit / RequestTrace / Admin 迁移。
- 不引入新 observability backend。

### 本 stage 验收

- docs、prompt、tool surface 对 13C 能力描述一致。
- `CURRENT.md` 下一步指向 13D 或真实 gateway/manual 验证。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/context_builder_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs`

## Review Fail 条件

- 13A/13B P1 findings 未修复就开始 13C。
- 新增第二个 agent-facing log/event/status 查询 tool。
- RunControl gauge 使用动态 per-session gauge name，而不是 workspace-level `run.owner.current`。
- Gauge 或 observations 存 full prompt、full response、full tool output、headers、body、patch content、`cancel_ref` 或 secret 明文。
- `RunControl` 因 ControlPlane 写入失败而拒绝 start/finish/fail/cancel。
- `/status` 触发 LLM、读 `/tmp/nex-agent-gateway.log`、或读任意 raw file。
- follow-up 回答错误/卡住/后台状态问题时，prompt 没要求先查 `observe`。
- follow-up tool surface 被扩大到 `self_update`、`apply_patch`、`bash`、`message` 等 side-effecting tools。
- InboundWorker task timeout/crash 只进 Logger，不进 ControlPlane。
- `/status` 和 `observe summary` 对同一 active owner run 的 phase/tool/queued 信息不一致。
- Tests 只覆盖 happy path，没有覆盖 owner failure、interrupt/cancel、timeout/crash、follow-up observe guidance。
