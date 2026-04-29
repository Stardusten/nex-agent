# Phase 8 Session Run Control And Busy Follow-up

## 当前状态

- `InboundWorker` 当前用 `active_tasks: %{key => pid}` 表示 session busy。
- busy session 收到普通消息时会进入 `pending_queue`，不会立即回答“进度如何”这类 follow-up。
- `/stop` 已经是 command catalog 中的 `bypass_busy?` 命令，但当前停止语义主要是 `Process.exit(pid, :kill)`：
  - 没有 run id
  - 没有 owner run / follow-up turn 区分
  - 没有工具子任务统一取消 contract
  - 没有 late result 丢弃 contract
  - streaming state 也没有以 run id 隔离
- `Nex.Agent.abort/1` 目前是空实现。
- `Runner` / `Tool.Registry` / tools 没有统一 cancellation token。
- 这导致两类目标都做不好：
  - 用户问“下载多少了？”时，无法立即基于当前 run 状态回答。
  - 用户明确 `/stop` 时，重工具或卡死逻辑可能无法足够及时停止。

## 完成后必须达到的结果

- 每个 session 有明确 busy / idle 状态。
- 每个 busy session 最多有一个 owner run。
- busy session 收到普通新消息时，默认启动 follow-up turn，不终止 owner run。
- follow-up turn 能读取 owner run 的最新可分享状态：
  - 当前 phase
  - 当前 tool
  - 最近 tool output tail
  - 最近 assistant partial
  - elapsed
  - queued count
- follow-up turn 不能成为第二个 owner run，不能拥有主 session 写权，不能随意调用有副作用工具。
- `/queue <message>` 明确排队到 owner run 结束后的下一轮。
- `/btw <message>` 明确作为 side question 立即回答，不终止 owner run，不写 owner run 主线历史。
- `/status` 直接读取 run state，立即返回，不调用 LLM。
- `/stop` 直接走 deterministic control lane，必须足够及时：
  - 不等待 LLM
  - 不等待 owner run 自愿检查取消
  - 立即标记 run cancelling / cancelled
  - 立即阻止旧 run late result 回写、发最终消息、写主线 session
  - 触发工具子任务 / subagent / stream transport 取消
- 旧 run late result 必须被 run id 丢弃。
- `docs/dev/*` 同步记录新的 session run control contract。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/findings/2026-04-17-cross-platform-slash-command-foundation.md`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/command/catalog.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/tool/bash.ex`
- `lib/nex/agent/tool/web_fetch.ex`
- `lib/nex/agent/tool/web_search.ex`
- `lib/nex/agent/tool/spawn_task.ex`
- `lib/nex/agent/subagent.ex`
- `lib/nex/agent/llm/req_llm.ex`
- `lib/nex/agent/channel/feishu/stream_state.ex`
- `lib/nex/agent/channel/discord/stream_state.ex`
- `test/nex/agent/inbound_worker_test.exs`
- `test/nex/agent/runner_stream_test.exs`
- `test/nex/agent/bash_tool_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. 用户控制层仍然归 `Nex.Agent.Conversation.Command.Catalog` / `Nex.Agent.Conversation.Command` / `InboundWorker` 所有。
   - 不允许把 `/stop`、`/queue`、`/btw`、`/status` 做成 LLM tool。
   - 不允许让模型决定是否执行硬停止。

2. 每个 session 的主执行权由 owner run 独占：

```elixir
%Nex.Agent.Conversation.RunControl.Run{
  id: String.t(),
  workspace: String.t(),
  session_key: String.t(),
  channel: String.t(),
  chat_id: String.t(),
  status: :running | :cancelling | :cancelled | :completed | :failed,
  kind: :owner,
  pid: pid() | nil,
  started_at_ms: integer(),
  updated_at_ms: integer(),
  current_phase: :starting | :llm | :tool | :streaming | :finalizing | :idle,
  current_tool: String.t() | nil,
  latest_tool_output_tail: String.t(),
  latest_assistant_partial: String.t(),
  queued_count: non_neg_integer(),
  cancel_ref: reference()
}
```

3. Follow-up turn 不是 owner run：

```elixir
%Nex.Agent.Conversation.RunControl.FollowUp{
  id: String.t(),
  owner_run_id: String.t(),
  workspace: String.t(),
  session_key: String.t(),
  question: String.t(),
  started_at_ms: integer()
}
```

Contract:
- follow-up turn 只允许读取 run snapshot 和有限历史。
- follow-up turn 不保存为主线 owner assistant turn。
- follow-up turn 不允许调用 `bash`、`write`、`edit`、`message`、`spawn_task`、`cron`、`memory_write` 等有副作用工具。
- follow-up turn 可以调用只读状态工具，或直接由 deterministic renderer 回答。

4. `RunControl` 对外最小接口冻结为：

```elixir
start_owner(workspace, session_key, attrs) ::
  {:ok, run} | {:error, :already_running}

finish_owner(run_id, result) :: :ok | {:error, :stale}

fail_owner(run_id, reason) :: :ok | {:error, :stale}

cancel_owner(workspace, session_key, reason) ::
  {:ok, %{cancelled?: boolean(), run_id: String.t() | nil}}

owner_snapshot(workspace, session_key) ::
  {:ok, run_snapshot} | {:error, :idle}

append_tool_output(run_id, tool_name, output) :: :ok | {:error, :stale}

append_assistant_partial(run_id, text) :: :ok | {:error, :stale}
```

5. `/stop` contract：
   - `/stop` 必须在 `pending_queue` / follow-up / LLM 之前处理。
   - `/stop` 必须同步返回用户可见确认。
   - `/stop` 必须立即使 session 对新 owner run 可用，不能等旧 run 自然结束。
   - 旧 run 的任何 async result 必须按 run id 丢弃。
   - `/stop` 不清 session grants，除非后续 phase 明确改变 approval contract。

6. `/queue <message>` contract：
   - busy 时只入队，不打断 owner run。
   - idle 时也允许入队，并在当前 tick 后启动下一 owner run。
   - 空参数返回 usage，不调用 LLM。

7. `/btw <message>` contract：
   - busy 时立即回答，不终止 owner run。
   - idle 时可以作为普通 side answer 处理，但不应创建 owner run。
   - 空参数返回 usage，不调用 LLM。

8. 普通消息 busy contract：
   - 默认不打断 owner run。
   - 进入 follow-up turn。
   - follow-up turn 可以回答“还在下载，最近输出是 ...”。
   - follow-up turn 不能把消息塞进 owner run 的主历史。

9. `Runner` / `Tool.Registry` cancellation contract：

```elixir
cancel_ref :: reference()
cancelled?(cancel_ref) :: boolean()
```

- `Runner` 每个迭代前后必须检查 cancel。
- LLM retry sleep 前后必须检查 cancel。
- tool 执行前后必须检查 cancel。
- `Tool.Registry` 必须记录 `run_id -> tool_task_pid`，支持按 run id 取消。
- 长工具必须能在取消时终止外部进程或 HTTP 请求；只杀外层 Task 不算完成。

10. Streaming contract：
    - stream state key 必须包含 run id。
    - owner run stop 后必须 finalize/cancel 当前 streaming transport。
    - 旧 run stream event 到达时必须被丢弃。

## 执行顺序 / stage 依赖

- Stage 1: 冻结 session run control contract 和测试骨架。
- Stage 2: 新增 RunControl 状态源，不接业务主链。
- Stage 3: InboundWorker 接入 owner run / run id / late result 丢弃。
- Stage 4: 新增 `/status`、`/queue`、`/btw` command 语义。
- Stage 5: busy 普通消息接 follow-up turn。
- Stage 6: `/stop` 硬控制面和 tool/subagent/stream cancellation。
- Stage 7: Runner / Tool.Registry cancellation 深入。
- Stage 8: 文档、CURRENT、验证和真实场景检查。

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 2。  
Stage 4 依赖 Stage 3。  
Stage 5 依赖 Stage 4。  
Stage 6 依赖 Stage 3。  
Stage 7 依赖 Stage 6。  
Stage 8 依赖 Stage 5、Stage 6、Stage 7。

## Stage 1

### 前置检查

- 确认当前代码没有半成品 run control 改动。
- 通读 `InboundWorker` busy queue、`/stop`、stream finalize 逻辑。

### 这一步改哪里

- `docs/dev/task-plan/phase8-session-run-control-and-followup.md`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`
- `docs/dev/task-plan/index.md`

### 这一步要做

- 冻结本 phase 的数据结构、command contract、cancellation contract。
- 明确“busy 普通消息默认 follow-up，不打断 owner run”。
- 明确“/stop 是 deterministic hard control，不走 LLM”。

### 实施注意事项

- 不写实现。
- 不把 follow-up 设计成完整第二 owner run。
- 不把 stop 做成 tool。

### 本 stage 验收

- phase 文档足够让后续执行者直接按 stage 实现。
- Review 能看到所有关键行为都有测试要求。

### 本 stage 验证

- 人工通读本 phase 文档。

## Stage 2

### 前置检查

- Stage 1 已合并。
- 当前 `InboundWorker.active_tasks` 仍是旧结构。

### 这一步改哪里

- 新增 `lib/nex/agent/run_control.ex`
- 新增 `test/nex/agent/run_control_test.exs`

### 这一步要做

- 实现 `Run` struct 和最小 in-memory GenServer。
- 支持 owner run start / finish / fail / cancel / snapshot。
- 支持 latest tool output tail 和 assistant partial 更新。
- 支持 queued count 更新。

### 实施注意事项

- RunControl 只存必要运行态，不缓存完整 runtime snapshot。
- 不读取配置文件。
- 不直接发消息。
- 不直接调用 channel / Runner / ToolRegistry。

### 本 stage 验收

- RunControl 能表达 idle / busy。
- run id 可防 stale finish 覆盖当前 run。
- cancel 后 snapshot 显示 cancelled 或 idle 的语义明确。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/run_control_test.exs
```

## Stage 3

### 前置检查

- Stage 2 test 通过。
- `RunControl` 已可 start / finish / cancel。

### 这一步改哪里

- `lib/nex/agent/inbound_worker.ex`
- `test/nex/agent/inbound_worker_test.exs`

### 这一步要做

- `dispatch_async` 创建 owner run id。
- async result 带 run id。
- `stream_states` key 包含 run id。
- owner run 成功 / 失败时用 run id finish / fail。
- stale async result 不发 outbound、不写 agent cache、不 drain queue。
- owner run 结束后 drain `/queue` 队列。

### 实施注意事项

- 不改变 busy 普通消息语义，仍先保持旧排队行为，避免 stage 过大。
- 不在此 stage 实现 follow-up LLM。
- 不在此 stage 深入工具取消。

### 本 stage 验收

- 旧 run late result 被丢弃。
- stream event 不会串到新 run。
- owner run lifecycle 在 RunControl 中可查询。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/inbound_worker_test.exs test/nex/agent/run_control_test.exs
```

## Stage 4

### 前置检查

- Stage 3 已经让 owner run 有 run id。
- command catalog 已是 user control truth source。

### 这一步改哪里

- `lib/nex/agent/command/catalog.ex`
- `lib/nex/agent/inbound_worker.ex`
- `test/nex/agent/inbound_worker_test.exs`
- 必要时 `lib/nex/agent/command/parser.ex`

### 这一步要做

- 新增 `/status`、`/queue`、`/btw`。
- `/status` 读取 RunControl snapshot 并直接回复。
- `/queue <message>` 入队，不打断 owner run。
- `/btw <message>` 暂时用 deterministic snapshot answer 或最小 side prompt，不写主线历史。

### 实施注意事项

- `/status` 必须不调用 LLM。
- `/queue` 空参数必须返回 usage。
- `/btw` 空参数必须返回 usage。
- `/btw` 不允许调用有副作用工具。

### 本 stage 验收

- busy 时 `/status` 立即返回。
- busy 时 `/queue second` 不影响 owner run，owner run 结束后执行 second。
- busy 时 `/btw progress?` 不终止 owner run。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/inbound_worker_test.exs
```

## Stage 5

### 前置检查

- Stage 4 `/status`、`/btw`、`/queue` 已完成。
- RunControl snapshot 有足够信息回答 progress 类问题。

### 这一步改哪里

- 新增 `lib/nex/agent/follow_up.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/runner.ex`
- `test/nex/agent/follow_up_test.exs`
- `test/nex/agent/inbound_worker_test.exs`

### 这一步要做

- busy 普通消息默认进入 follow-up turn。
- follow-up prompt 只包含：
  - 用户 follow-up 文本
  - owner run snapshot
  - 最近安全输出 tail
  - 明确禁止副作用工具的系统约束
- follow-up 使用 `tools_filter: :follow_up` 或完全无工具。
- follow-up 回复直接 outbound，不写 owner run 主历史。

### 实施注意事项

- 不允许 follow-up 复用 owner run 的 mutable session。
- 不允许 follow-up drain pending queue。
- follow-up 失败不能影响 owner run。
- follow-up 输出必须标记 metadata，例如 `_from_follow_up: true`，便于 channel/测试区分。

### 本 stage 验收

- busy 普通消息“下载多少了？”能立即回答，owner run 继续。
- owner run 完成后仍正常发 final。
- follow-up 不污染 owner session history。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/follow_up_test.exs test/nex/agent/inbound_worker_test.exs
```

## Stage 6

### 前置检查

- Stage 3 run id 已接入。
- Stage 4 `/stop` 仍是 command control。

### 这一步改哪里

- `lib/nex/agent/run_control.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/subagent.ex`
- channel stream state modules if needed
- `test/nex/agent/inbound_worker_test.exs`
- `test/nex/agent/run_control_test.exs`

### 这一步要做

- `/stop` 调 `RunControl.cancel_owner/3`。
- 取消 owner Task。
- 取消 subagent。
- 清 follow-up / queue 中与 stop 冲突的项。
- 取消或 finalize streaming state。
- 立即回复 stop 确认。
- late result 一律按 run id 丢弃。

### 实施注意事项

- `/stop` 不能等待工具自然结束后才释放 session。
- `/stop` 不能经过 LLM。
- stop 后第一条新普通消息必须能启动新 owner run。
- stop 不应把旧 partial 当成正常 final。

### 本 stage 验收

- 即使 owner run prompt_fun 永不返回，`/stop` 后 session 立即可用。
- 旧 run 后续返回不会发旧 final。
- streaming state 不残留。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/inbound_worker_test.exs test/nex/agent/run_control_test.exs
```

## Stage 7

### 前置检查

- Stage 6 已能取消 owner Task。
- 仍需解决重工具无法及时停的问题。

### 这一步改哪里

- `lib/nex/agent/runner.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/tool/bash.ex`
- `lib/nex/agent/tool/web_fetch.ex`
- `lib/nex/agent/tool/web_search.ex`
- tests:
  - `test/nex/agent/runner_stream_test.exs`
  - `test/nex/agent/bash_tool_test.exs`
  - 新增 `test/nex/agent/tool_registry_cancel_test.exs`

### 这一步要做

- Runner opts 增加 `run_id` / `cancel_ref`。
- Tool ctx 增加 `run_id` / `cancel_ref`。
- Tool.Registry 记录 active tool task，并暴露 `cancel_run(run_id)`。
- `bash` 工具改为可取消外部命令，不能只等 timeout。
- web tools / HTTP tools 在 cancel 后尽快返回 `{:error, :cancelled}` 或等价可识别错误。

### 实施注意事项

- 取消不能影响其他 session 或其他 run。
- 不能用全局单一 interrupt flag。
- 不打印敏感输出。
- 工具取消结果不能被当作正常 tool result 继续喂给 owner run；若 owner run 已 cancelled，直接丢弃。

### 本 stage 验收

- `/stop` 能打断正在执行的长 bash。
- `/stop` 能打断正在等待的 HTTP/web tool。
- 一个 session stop 不影响另一个 session 的 tool。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_registry_cancel_test.exs test/nex/agent/bash_tool_test.exs test/nex/agent/inbound_worker_test.exs
```

## Stage 8

### 前置检查

- Stages 2-7 全部通过 targeted tests。

### 这一步改哪里

- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`
- 必要时 `docs/dev/findings/YYYY-MM-DD-session-run-control.md`

### 这一步要做

- 更新 CURRENT active workstream。
- 记录最终 contract 和已知限制。
- 如果真实 gateway 验证过，记录真实命令和结果。

### 实施注意事项

- 不把实现过程流水账写入 finding。
- finding 只写影响后续架构判断的结论。

### 本 stage 验收

- 后续执行者能从 CURRENT 找到 phase8。
- phase8 验证命令清楚。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/inbound_worker_test.exs test/nex/agent/run_control_test.exs
/Users/krisxin/.local/bin/mise exec -- mix compile
```

## Review Fail 条件

- busy 普通消息默认打断 owner run。
- follow-up turn 可以写 owner run 主线 session history。
- follow-up turn 能调用有副作用工具。
- `/stop` 需要 LLM 或 tool 调用才能生效。
- `/stop` 后旧 run late result 还能发 final 或覆盖 agent cache。
- `/stop` 只杀外层 Task，长工具子任务继续跑且没有 registry 取消入口。
- stream state 不按 run id 隔离。
- `RunControl` 缓存完整 runtime snapshot、config、prompt 或 tool definitions。
- 新增一套平行配置读取逻辑。
