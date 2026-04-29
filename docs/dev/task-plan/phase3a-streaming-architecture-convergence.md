# Phase 3A Streaming Architecture Convergence

## 当前状态

- phase3 主路径已经落地，至少 Feishu 已经能走用户可见流式输出。
- `%Nex.Agent.Stream.Event{}` 和 `%Nex.Agent.Turn.Stream.Result{}` 已经存在，`InboundWorker` 也已经按 stream session 驱动 transport 收尾。
- 当前主要技术债不是“功能缺失”，而是 streaming 协议细节开始回流到 `Runner` 与中心化 `Transport` dispatcher。
- reviewer 已指出 `Runner` 过重、`Transport` 不够自然、`MessageSession` 命名不准、consolidation 共用 streaming machinery 边界偏硬；这些判断已经在现代码中得到验证。
- 对应架构结论见：
  - [2026-04-16 Streaming Architecture Convergence](../findings/2026-04-16-streaming-architecture-convergence.md)

## 完成后必须达到的结果

- `Runner` 不再自己维护 conversation drain 和 consolidation drain 两套 receive/assemble 状态机。
- provider raw stream 累积逻辑被收敛到独立 assembler，conversation path 与 consolidation path 共用同一份 assembled state machinery。
- `Transport` 不再直接持有 Feishu 之类的平台副作用分支；平台实现自己负责创建 carrier 与执行平台动作。
- `MessageSession` 更名为能力导向命名 `MultiMessageSession`。
- streaming transport 内部 finalize contract 收紧为 `%Nex.Agent.Turn.Stream.Result{}`，不再把旧 string / `:message_sent` 兼容继续扩散到新的 stream session 层。
- 阶段结束时仓库仍保持已存在的 Feishu 流式主路径行为，不得因为重构退回“一次性整段发完”。

## 开工前必须先看的代码路径

- `lib/nex/agent/runner.ex`
- `lib/nex/agent/llm/req_llm.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/stream/event.ex`
- `lib/nex/agent/stream/result.ex`
- `lib/nex/agent/stream/session.ex`
- `lib/nex/agent/stream/transport.ex`
- `lib/nex/agent/stream/feishu_session.ex`
- `lib/nex/agent/stream/message_session.ex`
- `test/nex/agent/inbound_worker_test.exs`
- `test/nex/agent/llm/req_llm_test.exs`
- streaming 架构判断先看：
  - [2026-04-16 Streaming Architecture Convergence](../findings/2026-04-16-streaming-architecture-convergence.md)
  - [Phase 3 Streaming Delivery Contract](./phase3-streaming-delivery-contract.md)

## 固定边界 / 已冻结的数据结构与 contract

本 phase3a 固定以下边界。

1. `ReqLLM.stream/3` 对上游暴露的 raw callback event 形状暂不改：

```elixir
{:delta, text}
| {:thinking, text}
| {:tool_calls, tool_calls}
| {:done, metadata}
| {:error, reason}
```

2. `%Nex.Agent.Stream.Event{}` 与 `%Nex.Agent.Turn.Stream.Result{}` 的外部语义不改。
   - phase3a 是内部层次收敛，不是重新定义用户可见 streaming contract。
3. 新增 assembler 后，职责冻结为：
   - 累积 raw provider stream state
   - 产出 assembled response
   - 在 conversation mode 下按规则发 unified `Stream.Event`
   - 在 consolidation mode 下不发用户可见事件
4. assembler state 至少要冻结以下字段：

```elixir
%{
  content_parts: [String.t()],
  reasoning_parts: [String.t()],
  tool_calls: [map()],
  finish_reason: String.t() | nil,
  usage: map() | nil,
  model: String.t() | nil,
  error: term() | nil,
  message_started?: boolean(),
  seq: non_neg_integer()
}
```

5. `Runner` 不得再直接持有以下 streaming 内部状态：
   - `content_parts`
   - `reasoning_parts`
   - `tool_calls`
   - `finish_reason`
   - `message_started` process dictionary
   - `seq` process dictionary
6. transport implementation contract 冻结为“实现模块自行处理平台副作用”。
   - 协议入口层可以选择实现模块，但不能自己写平台分支副作用。
7. `Transport` 层的第一版实现冻结为两个实现：
   - Feishu edit-message implementation
   - multi-message fallback implementation
8. `MessageSession` 更名后，能力语义冻结为 `:multi_message` fallback。
   - 不把它表述成“通用消息 session 基类”。
9. streaming transport finalize 内部 contract 冻结为：

```elixir
@callback finalize_success(term(), Nex.Agent.Turn.Stream.Result.t()) ::
            {term(), [action()], boolean()}

@callback finalize_error(term(), Nex.Agent.Turn.Stream.Result.t()) ::
            {term(), [action()], boolean()}
```

10. 非 streaming 结果兼容只允许留在 `InboundWorker` 边界或更外层。
    - 不允许把 string / `:message_sent` 继续下沉进新的 stream implementation。
11. consolidation 在 phase3a 结束后仍可继续使用 `ReqLLM.stream/3`，但必须通过 assembler 的 non-conversation mode 收敛，而不是保留独立 drain 状态机。
12. phase3a 不负责新增 Slack native stream 或 Telegram/Discord edit adapter。

## 执行顺序 / stage 依赖

- Stage 1: 抽出 provider stream assembler
- Stage 2: 让 `Runner` conversation path 与 consolidation path 共用 assembler
- Stage 3: 收紧 transport implementation 边界并下沉平台副作用
- Stage 4: 清理命名与 finalize contract
- Stage 5: 回归验证与 reviewer 检查点

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1。  
Stage 4 依赖 Stage 3。  
Stage 5 依赖 Stage 2 和 Stage 4。

## Stage 1

### 前置检查

- 读清 `ReqLLM.stream/3` 现有 callback event 形状。
- 读清 `Runner.call_llm_stream/2` 与 consolidation drain 的差异点。
- 确认 phase3 外部 contract 已由 `%Stream.Event{}` / `%Stream.Result{}` 覆盖，不需要在这一 stage 改协议。

### 这一步改哪里

- 新增 `lib/nex/agent/stream/assembler.ex`
- 更新 `lib/nex/agent/stream/event.ex`
- 更新 `lib/nex/agent/stream/result.ex`
- 更新 `lib/nex/agent/runner.ex`
- 新增 `test/nex/agent/stream/assembler_test.exs`

### 这一步要做

- 定义 assembler 模块，最少提供：
  - `new/1`
  - `consume/2`
  - `finalize/1`
- assembler `consume/2` 必须只理解 raw provider events：
  - `{:delta, text}`
  - `{:thinking, text}`
  - `{:tool_calls, tool_calls}`
  - `{:done, metadata}`
  - `{:error, reason}`
- assembler 必须能在 `mode: :conversation` 时产出 unified `Stream.Event`：
  - 首次可见文本前只发一次 `:message_start`
  - 每个 `:text_delta` 保证 `seq` 单调递增
  - `finalize/1` 时补 `:message_end`
- assembler 必须能在 `mode: :consolidation` 时只累积 response，不发 unified `Stream.Event`
- assembler 负责 `message_started?` 与 `seq`，禁止继续依赖 `Runner` process dictionary
- assembler `finalize/1` 统一返回 assembled response shape，至少包含：
  - `content`
  - `reasoning_content`
  - `tool_calls`
  - `finish_reason`
  - `model`
  - `usage`
  - `streamed_text`
  - `error`

### 实施注意事项

- 这一 stage 先抽出 state machine，不强求 transport 同时重写。
- 不要把 unified `Stream.Event` 生成逻辑留一半在 assembler、一半在 `Runner`。
- 不要为了兼容当前实现继续把 `seq` / `message_started` 藏在 process dictionary。
- `finalize/1` 必须是纯 assembler state 收尾，不允许再写第二份临时 response map 拼装代码。

### 本 stage 验收

- 仓库里存在单独 assembler，而不是 `Runner` 内联 receive/drain 状态机。
- assembler 单独可测，conversation mode 与 consolidation mode 都有明确行为。
- reviewer 能直接看到 seq/message_started 已从 `Runner` process dictionary 移走。

### 本 stage 验证

- 新增单测覆盖：
  - conversation mode 下 message_start 只发一次
  - seq 严格递增
  - consolidation mode 不发 unified event
  - finalize 返回 assembled response
  - raw error 转成 assembler error state
- 运行：
  - `mix test test/nex/agent/stream/assembler_test.exs`

## Stage 2

### 前置检查

- Stage 1 assembler 已通过单测。
- 明确 `Runner` 现有 conversation path 与 consolidation path 的输出期望。

### 这一步改哪里

- `lib/nex/agent/runner.ex`
- `test/nex/agent/llm/req_llm_test.exs`
- `test/nex/agent/inbound_worker_test.exs`
- 需要时更新 consolidation 相关测试：
  - `test/nex/agent/memory_rebuild_test.exs`
  - `test/nex/agent/memory_updater_test.exs`
  - `test/nex/agent/memory_consolidate_test.exs`

### 这一步要做

- 用 assembler 重写 `Runner.call_llm_stream/2` 主链。
- 删除 conversation path 的 `drain_stream_events/3` 式内联状态机。
- 用 assembler 重写 consolidation path。
- 删除 `drain_consolidation_stream_events/2` 这套重复状态机。
- 保持对外返回值不变：
  - conversation streaming path 继续返回 `%Stream.Result{}`
  - consolidation 继续返回 tool extraction 所需 response
- 保持现有 `_suppress_current_reply_stream` 行为语义，但由 assembler conversation mode 消化。

### 实施注意事项

- 这一 stage 不要顺手改 transport。
- conversation path 和 consolidation path 必须共用同一份 raw event accumulation 逻辑，不能只是把重复代码移动到另一个模块后保留两套分支。
- 如果 memory/consolidation 旧失败与已知 baseline 相同，不视为 phase3a 回归。

### 本 stage 验收

- `Runner` 中不存在两套独立 raw stream drain 状态机。
- consolidation 不再直接拼 receive-loop，而是通过 assembler 取最终 response。
- Feishu 现有流式主路径行为不退化。

### 本 stage 验证

- 跑最小回归：
  - `mix test test/nex/agent/llm/req_llm_test.exs test/nex/agent/inbound_worker_test.exs`
- 若需要验证 consolidation 接线：
  - `mix test test/nex/agent/memory_rebuild_test.exs test/nex/agent/memory_updater_test.exs test/nex/agent/memory_consolidate_test.exs`
- 验证时对照已知 baseline：
  - `MemoryRebuildTest` prompt memory block 失败
  - `MemoryUpdaterTest` prompt memory block 失败
  - `MemoryConsolidateTest` `already_running` timeout
  - `RunnerEvolutionTest` async consolidation history 未更新

## Stage 3

### 前置检查

- `InboundWorker.build_stream_sink/5`、`Transport.open_session/4`、`run_stream_actions/1` 当前职责已读清楚。
- 明确当前平台特化泄漏点：
  - `Transport.open_session/4` 里的 `Feishu.send_card/3`
  - `InboundWorker.run_stream_actions/1` 里的 `:update_card`

### 这一步改哪里

- 新增 `lib/nex/agent/stream/transport_behaviour.ex`
- 新增 `lib/nex/agent/stream/transports/feishu.ex`
- 新增 `lib/nex/agent/stream/transports/multi_message.ex`
- 更新 `lib/nex/agent/stream/transport.ex`
- 更新 `lib/nex/agent/inbound_worker.ex`
- 需要时调整 `lib/nex/agent/stream/session.ex`
- 新增 `test/nex/agent/stream/transport_test.exs`

### 这一步要做

- 定义 transport implementation behaviour，至少包含：
  - `open_session/4`
  - `handle_event/2`
  - `finalize_success/2`
  - `finalize_error/2`
  - `run_actions/1`
- `Transport` 保留为协议入口，但只负责：
  - 选择 implementation
  - 委托调用 implementation
- 把 Feishu 初始 card 创建下沉到 Feishu transport implementation。
- 把 Feishu card update 执行从 `InboundWorker.run_stream_actions/1` 下沉到 transport implementation。
- multi-message fallback 形成独立 implementation，不再作为“默认 message session 杂糅进 dispatcher”。
- `InboundWorker` 只负责：
  - 持有 stream session state
  - 把 event / finalize 交给 transport
  - 调 transport 执行动作

### 实施注意事项

- 不要把实现选择继续硬编码成更多 channel 分支。
- 这一 stage 允许先用显式 module map 选择 implementation，不要求一步到位做复杂 registry。
- transport action 命名要避免平台专属词泄漏到协议入口层。
- 如果 action 仍需要有实现私有 shape，应由 implementation 自己解释和执行。

### 本 stage 验收

- `Transport.open_session/4` 不再直接调用 `Nex.Agent.Channel.Feishu.send_card/3`。
- `InboundWorker.run_stream_actions/1` 不再知道 `:update_card` 这类平台动作。
- reviewer 能直接看到平台副作用已下沉到 transport implementation。

### 本 stage 验证

- 新增单测覆盖：
  - Feishu implementation open/finalize/action drain
  - multi-message implementation fallback
  - `Transport` 只做委托，不做平台副作用
- 运行：
  - `mix test test/nex/agent/stream/transport_test.exs test/nex/agent/inbound_worker_test.exs`

## Stage 4

### 前置检查

- Stage 3 transport implementation 已就位。
- 明确 streaming path 内部已全部走 `%Stream.Result{}`。

### 这一步改哪里

- `lib/nex/agent/stream/message_session.ex`
- `lib/nex/agent/stream/session.ex`
- `lib/nex/agent/stream/transport.ex`
- `lib/nex/agent/inbound_worker.ex`
- 所有引用 `MessageSession` 的测试和模块
- 需要时新增 shim-free rename：
  - `lib/nex/agent/stream/multi_message_session.ex`

### 这一步要做

- 直接把 `MessageSession` 重命名为 `MultiMessageSession`。
- 更新全部调用点，不保留 repo 内部兼容别名。
- 把 streaming transport finalize contract 收紧到 `%Stream.Result{}`。
- 将 string / `:message_sent` 到 `%Stream.Result{}` 的桥接收口到 `InboundWorker` 或 transport 入口外层。
- 清理 session 层中仅为旧返回值保留的分支。

### 实施注意事项

- 按 repo 规则，不要为了中间可编译状态保留旧 API alias。
- 先删旧名字，再用编译错误驱动所有调用点更新。
- 这一 stage 不改变用户可见 flush 规则，只改命名和边界。

### 本 stage 验收

- 仓库中不再存在 `MessageSession` 这个内部正式名字。
- stream transport finalize 内部 contract 只围绕 `%Stream.Result{}`。
- 新 transport implementation 不需要再兼容旧 string / `:message_sent` 三套语义。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/inbound_worker_test.exs test/nex/agent/stream/transport_test.exs`
- 用 `rg` 自检：
  - `rg -n "MessageSession|:message_sent|finalize_success\\(" lib test`

## Stage 5

### 前置检查

- 前四个 stage 已完成并通过对应最小测试。
- 明确 phase3a 的验收不是新增平台，而是让现有 phase3 主链更自然、更可扩展。

### 这一步改哪里

- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`
- 需要时补测试或 findings 交叉引用

### 这一步要做

- 做一次 reviewer 视角自检，确认下面 4 个问题都已被结构性处理，而不是换名不换层：
  - `Runner` 不再自持双状态机
  - consolidation 不再走用户对话 event assembly
  - `Transport` 不再是平台副作用 dispatcher
  - `MultiMessageSession` 命名与能力匹配
- 记录 residual risk：
  - Slack native stream 仍未接入
  - Telegram/Discord edit adapter 仍待后续阶段
  - memory baseline 旧失败不计入本阶段回归

### 实施注意事项

- 验证优先跑窄测试。
- 如果 live channel 验证需要凭证，文档中明确标记未执行，不要假设通过。

### 本 stage 验收

- reviewer 可以直接把 phase3a 看成“架构收敛层”，不是额外 feature phase。
- 仓库保持 Feishu 流式能力，同时为后续新 transport 留出自然边界。

### 本 stage 验证

- 最小建议命令：
  - `mix test test/nex/agent/stream/assembler_test.exs test/nex/agent/stream/transport_test.exs test/nex/agent/inbound_worker_test.exs test/nex/agent/llm/req_llm_test.exs`
- 如需补主链回归：
  - `mix test test/nex/agent/runner_evolution_test.exs`

## Review Fail 条件

- `Runner` 里仍保留 conversation 与 consolidation 两套 raw stream drain 状态机。
- assembler 只是挪文件，没有真正接管 `seq` / `message_started` / assembled state。
- `Transport` 入口层仍直接调用平台模块副作用。
- `InboundWorker` 仍直接识别平台私有 action 名。
- `MessageSession` 只是改文件名，内部 contract 仍继续吞 string / `:message_sent`。
- 为了 phase3a 暂时可编译而保留 repo 内部兼容 alias 或双 API。
