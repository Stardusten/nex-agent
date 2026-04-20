# Phase 9 Follow-up LLM Turn And Interrupt Request

## 当前状态

- Phase 8 已经落地了 owner run / busy state / `/stop` / `/status` / `/queue` / `/btw` 的第一版 contract。
- 当前 busy session 收到普通消息时，不会打断 owner run，这点已经符合主方向。
- 但现在的 follow-up 还只是 deterministic 文本回复，不是真正的 follow-up LLM turn：
  - `InboundWorker` busy 分支直接调用 `FollowUp.render_busy_follow_up/2`
  - `/btw` 也是直接渲染字符串
- `RunControl` 当前只保存最小 owner snapshot：
  - `current_phase`
  - `current_tool`
  - `latest_tool_output_tail`
  - `latest_assistant_partial`
  - `queued_count`
- 这已经足够支持“看见正在运行的最新上下文”的最小版本，不需要再引入第二套复杂运行时状态模型。
- 当前代码已经具备两个可复用基础，不应重复造轮子：
  - `Nex.Agent.prompt/3` 在 `skip_consolidation: true` 时会使用临时 session，不污染主 session
  - `Runner` / `Tool.Registry` 已支持 `tools_filter: :follow_up`
- 当前还缺最后一段关键行为：
  - busy 普通消息和 `/btw` 应该触发一个真正的 follow-up LLM turn
  - follow-up turn 能读取 owner run 最新可分享状态
  - follow-up turn 只能走受限只读工具
  - follow-up turn 可以请求打断当前 session，但真正打断仍必须走统一 deterministic control lane

## 完成后必须达到的结果

- busy session 收到普通新消息时，默认不打断 owner run。
- 该消息会触发一个真正的 follow-up LLM turn，而不是模板字符串回复。
- follow-up LLM turn 能看到 owner run 的最新可分享上下文，至少包括：
  - 当前 phase
  - 当前 tool
  - 最近 tool output tail
  - 最近 assistant partial
  - elapsed
  - queued count
- follow-up LLM turn 不能成为第二个 owner run。
- follow-up LLM turn 不写 owner 主 session 历史，不触发 memory consolidation。
- `/btw <message>` 走同一条 follow-up LLM turn 管道。
- `/status` 仍保持 deterministic，不调用 LLM。
- `/stop` 仍保持 deterministic，不通过 LLM 决定是否执行。
- 系统提供一个统一 interrupt request 入口，供 deterministic command 和可选的薄 tool 共用。
- 如果提供 follow-up 用 interrupt tool，它只能是 control lane 的薄封装，不能在 tool 内另起一套停止逻辑。
- 最终验收必须对齐本 phase 初始目标，不允许实现跑偏成：
  - busy 时直接 interrupt owner run
  - follow-up 变成第二个 owner run
  - follow-up 能调用副作用工具
  - 用复杂新抽象替代现有 `RunControl + InboundWorker + prompt/3` 主链

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/task-plan/phase8-session-run-control-and-followup.md`
- `lib/nex/agent.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/follow_up.ex`
- `lib/nex/agent/run_control.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/command/catalog.ex`
- `test/nex/agent/inbound_worker_test.exs`
- `test/nex/agent/run_control_test.exs`
- `test/nex/agent/message_tool_test.exs`
- `test/nex/agent/runner_stream_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. owner run 模型沿用 Phase 8，不重做状态机。

- 不新增第二套 owner registry。
- 不新增 session 级 event store。
- 不把 `RunControl` 扩成完整 runtime world view cache。

冻结 shape：

```elixir
%Nex.Agent.RunControl.Run{
  id: String.t(),
  workspace: String.t(),
  session_key: String.t(),
  channel: String.t(),
  chat_id: String.t(),
  status: :running | :cancelling,
  kind: :owner,
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

2. follow-up turn 是最小执行模式，不是新长期状态源。

- 不要求新增持久化 `FollowUp` struct。
- 不要求 `RunControl` 跟踪所有 follow-up 生命周期。
- `InboundWorker` 只需要知道“正在跑一个短生命周期 follow-up task”，避免同一条消息同步阻塞即可。

冻结行为：

- follow-up turn 输入 = 用户 follow-up 问题 + owner snapshot + 少量必要历史
- follow-up turn 输出 = 直接 side reply
- follow-up turn 不写主 session history
- follow-up turn 不触发 memory consolidation
- follow-up turn 不拥有 owner 写权

3. follow-up turn 必须复用现有执行入口。

- 必须通过 `Nex.Agent.prompt/3` 运行。
- 必须使用：

```elixir
skip_consolidation: true
tools_filter: :follow_up
```

- 不允许新增第二套 “follow-up runner” 或 “mini runner”。

4. follow-up 可分享上下文来源保持最小。

- 默认只读 `RunControl.owner_snapshot/2`。
- 不新增大而全的 event log。
- 如确实不够，只允许在 `RunControl.Run` 上补 1 到 2 个字段；不能为此新建独立日志子系统。

5. 用户控制权的真相源仍归 command/control lane 所有。

- `/stop` 仍然是 deterministic command。
- `/status` 仍然是 deterministic command。
- `/queue` 仍然是 deterministic command。
- 模型不能自行决定是否硬停止 owner run。

6. interrupt request 入口必须统一。

冻结接口：

```elixir
request_interrupt(workspace, session_key, reason, opts) ::
  {:ok, %{cancelled?: boolean(), run_id: String.t() | nil}}
```

Contract:

- 默认实现可直接委托到现有 stop/cancel owner 主链
- `/stop` 调这个入口
- 可选的 follow-up tool 也只能调这个入口
- 不允许 tool 内部自己 `Process.exit/2`
- 不允许在多个模块里各写一份 cancel orchestration

7. follow-up 工具权限必须严格冻结为只读最小集合。

允许：

```elixir
~w(
  executor_status
  list_dir
  memory_status
  read
  skill_discover
  skill_get
  tool_list
  web_fetch
  web_search
)
```

禁止：

```elixir
~w(
  bash
  edit
  write
  message
  spawn_task
  cron
  memory_write
)
```

8. 可选 interrupt tool 只是薄封装，不是新控制面。

冻结定义：

- 名称可为 `interrupt_session`
- 只在 `:follow_up` tool surface 暴露
- 入参只允许：

```elixir
%{
  "reason" => String.t()
}
```

Contract:

- 内部只调用统一 `request_interrupt/4`
- 不直接操作 pid / stream state / tool registry / subagent
- 不在 owner run surface 暴露

9. 验收必须回到本 phase 的设计初目标。

目标原文对齐：

- 每个 session 都有状态，busy 或 idle
- busy 时收到新消息，默认不打断
- 新 LLM 能看到正在运行的最新上下文
- 提供打断当前 session 的能力

本 phase 的具体解释冻结为：

- busy / idle：沿用 Phase 8 owner snapshot
- 默认不打断：普通消息和 `/btw` 都进入 follow-up turn
- 新 LLM 能看到最新上下文：来自 `RunControl.owner_snapshot/2`
- 提供打断能力：`/stop` 必达；可选 follow-up tool 作为薄入口

## 执行顺序 / stage 依赖

- Stage 1: 冻结最小 contract 和测试骨架。
- Stage 2: 把 follow-up 入口改成真正的 follow-up LLM turn。
- Stage 3: 跑通 follow-up prompt/context 组装和只读工具过滤。
- Stage 4: 新增统一 interrupt request 入口，并把 `/stop` 收敛到该入口。
- Stage 5: 可选新增 `interrupt_session` 薄 tool，仅暴露给 follow-up surface。
- Stage 6: 文档、回归、手工验收。

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 2。  
Stage 4 依赖 Stage 1。  
Stage 5 依赖 Stage 4。  
Stage 6 依赖 Stage 3、Stage 4。  

## Stage 1

### 前置检查

- 通读 Phase 8 文档和现有 `RunControl` / `InboundWorker` 实现。
- 确认当前 follow-up 仍是 deterministic renderer，不是真 LLM turn。
- 确认现有 `Nex.Agent.prompt/3` 已支持 `skip_consolidation: true` 和 `tools_filter: :follow_up`。

### 这一步改哪里

- `docs/dev/task-plan/phase9-follow-up-llm-turn-and-interrupt-request.md`
- `docs/dev/task-plan/index.md`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`

### 这一步要做

- 冻结本 phase 的最小 contract。
- 明确 follow-up 复用现有 prompt/runner 主链，不新增复杂执行框架。
- 明确 interrupt tool 只是可选薄封装，不替代 `/stop`。

### 实施注意事项

- 不写实现。
- 不引入新的长期状态模型。
- 不把 Phase 8 已有 contract 推翻重来。

### 本 stage 验收

- 文档中已经写清楚“最小抽象”和“禁止过度设计”的边界。
- reviewer 能从文档直接判断哪些实现会跑偏。

### 本 stage 验证

- 人工通读 phase 文档。

## Stage 2

### 前置检查

- Stage 1 已合并。
- 当前 `InboundWorker` busy 路径仍调用 `FollowUp.render_busy_follow_up/2`。

### 这一步改哪里

- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/follow_up.ex`
- `test/nex/agent/inbound_worker_test.exs`

### 这一步要做

- 在 `InboundWorker` 中新增 follow-up dispatch 主链：
  - busy 普通消息不再直接渲染字符串
  - `/btw` 不再直接渲染字符串
  - 改为异步触发一个 follow-up task
- follow-up task 内部复用 `state.agent_prompt_fun/3` 或 `Nex.Agent.prompt/3`：
  - `skip_consolidation: true`
  - `tools_filter: :follow_up`
  - `schedule_memory_refresh: false`
  - 不传 owner 写权
- follow-up 结果直接 outbound，且带 `_from_follow_up: true`

### 实施注意事项

- follow-up 不能复用 owner run id。
- follow-up 不能落到 `pending_queue`。
- follow-up 失败不能把 owner run 置为 failed。

### 本 stage 验收

- busy 普通消息收到的是 follow-up LLM reply，不再是模板字符串。
- `/btw` 也走 follow-up LLM reply。
- owner run 继续运行，不被默认中断。

### 本 stage 验证

- `mix test test/nex/agent/inbound_worker_test.exs`

## Stage 3

### 前置检查

- Stage 2 已合并。
- `FollowUp` 模块已从纯 renderer 演进为 follow-up context builder。

### 这一步改哪里

- `lib/nex/agent/follow_up.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/tool/registry.ex`
- `test/nex/agent/inbound_worker_test.exs`
- `test/nex/agent/message_tool_test.exs`

### 这一步要做

- 在 `FollowUp` 中实现最小 prompt/context builder：
  - owner snapshot 文本化
  - 当前用户 follow-up 问题
  - 必要规则提示
- 规则必须明确：
  - 你不是 owner run
  - 不要修改主任务
  - 不要调用副作用工具
  - 如用户明确要求停止，可调用 interrupt request tool（若该 tool 已开放）
- 复查 `:follow_up` tool surface：
  - 只能暴露冻结的只读工具
  - 不得把 `bash` / `write` / `message` 等漏进来

### 实施注意事项

- 不为了“上下文更丰富”去新增事件日志系统。
- owner snapshot 不够时，只允许补最少字段，不允许上升成新子系统。
- 不让 follow-up 读取整份 session transcript。

### 本 stage 验收

- follow-up LLM 能回答“现在到哪了”“刚才工具输出了什么”这类问题。
- follow-up 工具面保持只读。

### 本 stage 验证

- `mix test test/nex/agent/inbound_worker_test.exs`
- `mix test test/nex/agent/message_tool_test.exs`

## Stage 4

### 前置检查

- Phase 8 的 `/stop` 已可取消 owner run。
- 当前 stop/cancel orchestration 仍散在 `InboundWorker` 若干 helper 中。

### 这一步改哪里

- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/run_control.ex`
- `test/nex/agent/inbound_worker_test.exs`
- `test/nex/agent/run_control_test.exs`

### 这一步要做

- 新增统一 interrupt request 入口。
- 把 `/stop` 的执行收敛到该入口。
- 入口内部复用现有：
  - owner cancel
  - tool registry cancel
  - subagent cancel
  - stream finalize/cancel
- 返回值冻结为：

```elixir
{:ok, %{cancelled?: boolean(), run_id: String.t() | nil}}
```

### 实施注意事项

- 这是 control lane 收口，不是新一层 façade。
- 不把真正的 orchestration 散到 tool 里。
- 不改 `/stop` 的用户可见 contract。

### 本 stage 验收

- `/stop` 和内部 cancel 请求最终都走同一入口。
- stop 后旧 run 结果仍按 run id 丢弃。

### 本 stage 验证

- `mix test test/nex/agent/run_control_test.exs`
- `mix test test/nex/agent/inbound_worker_test.exs`

## Stage 5

### 前置检查

- Stage 4 已合并。
- follow-up turn 已能跑真实 LLM reply。

### 这一步改哪里

- 新增 `lib/nex/agent/tool/interrupt_session.ex`
- `lib/nex/agent/tool/registry.ex`
- `test/nex/agent/message_tool_test.exs`
- `test/nex/agent/inbound_worker_test.exs`

### 这一步要做

- 可选新增 `interrupt_session` 薄 tool。
- 该 tool 只在 `:follow_up` surface 暴露。
- 该 tool 内部只调用统一 interrupt request 入口。
- prompt 规则要求：只有当用户明确表达停止、取消、不要继续、改道时才允许调用。

### 实施注意事项

- 这是可选 stage；如果 deterministic `/stop` 已满足产品目标，可以在 reviewer 同意下跳过。
- 即使实现该 tool，也不能让 owner run surface 默认看到它。
- 不允许这个 tool 直接操作 pid 或进程树。

### 本 stage 验收

- follow-up LLM 在明确用户意图下可以请求停止当前 session。
- 该停止行为与 `/stop` 结果一致，不存在双轨控制。

### 本 stage 验证

- `mix test test/nex/agent/message_tool_test.exs`
- `mix test test/nex/agent/inbound_worker_test.exs`

## Stage 6

### 前置检查

- Stage 2 到 Stage 4 已完成。
- 若实现了 Stage 5，也必须一并回归。

### 这一步改哪里

- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`
- 需要补充时更新相关 findings

### 这一步要做

- 回归自动化测试。
- 用真实 gateway/manual 场景验收本 phase 是否对齐初始目标。
- 把实际结论写入 `docs/dev/progress/*`。

### 实施注意事项

- 验收必须回到最初目标，不看实现花样。
- 如果发现 follow-up 为了回答问题而频繁想调用副作用工具，应优先收紧 prompt/tool surface，而不是再加新状态抽象。

### 本 stage 验收

- 下列场景全部成立：
  - 长任务运行中发普通消息，不默认打断
  - follow-up LLM 能基于当前运行态回答
  - `/btw` 行为与普通 busy follow-up 一致，只是入口更显式
  - `/status` 仍然 deterministic
  - `/stop` 仍然 deterministic 且立即生效
  - 若实现了 `interrupt_session`，它只是 `/stop` 同源入口的薄封装
- reviewer 能确认实现没有跑偏成过度设计。

### 本 stage 验证

- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/run_control_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/inbound_worker_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/message_tool_test.exs`
- `/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/runner_stream_test.exs`
- 手工 gateway 验证：
  - 启动一个长任务
  - 中途发“现在到哪了”
  - 中途发“顺便问个问题”
  - 中途发“停掉这个任务”
  - 检查 owner run、follow-up reply、stop、生效时序是否符合初始目标

## Review Fail 条件

- busy 普通消息仍只是 deterministic 模板回复，没有真实 follow-up LLM turn。
- follow-up turn 会写主 session history 或触发 memory consolidation。
- follow-up turn 获得了副作用工具权限。
- 为了实现 follow-up，引入新的长期状态机、事件日志系统或第二套 runner。
- `interrupt_session` 若存在，却没有走统一 interrupt request 入口。
- `/stop` 被弱化为依赖 LLM/tool 决策。
- 最终行为偏离本 phase 初始目标：
  - busy 默认打断 owner run
  - follow-up 看不到最新运行态
  - 打断能力不可用或变得不确定
