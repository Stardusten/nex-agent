# Phase 3 Streaming Delivery Contract

## 当前状态

- `SOUL.md` 可以影响文风，但不能改变当前主链“一次拿完整 reply，再一次性发出去”的交付形态。
- `ReqLLM.stream/3` 已经存在，但 `Runner` 没有把它接进主路径。
- `InboundWorker` 当前的 progress callback 只承担 tool hint / thinking 提示，不承担 assistant 正文增量发送。
- 各 IM channel 的能力边界不一致：
  - Slack 已确认同时支持原生 stream API 与消息编辑
  - Telegram / Discord 已确认支持消息编辑，但不是原生 token stream
  - Feishu 当前仓库已有 card patch 能力
  - DingTalk 当前仓库只有普通发送主链
- reviewer 需要能快速核对外部资料，因此平台能力判断与来源已经单独记录在：
  - [2026-04-16 IM Streaming Capabilities And Delivery Contract](../findings/2026-04-16-im-streaming-capabilities.md)

## 完成后必须达到的结果

- `nex-agent` 形成统一的“assistant 增量事件流”主链，而不是继续以最终字符串为核心接口。
- `Runner` 能在不依赖最终完整 reply 的情况下向上游持续产出 assistant / tool 事件。
- channel 层通过统一 transport contract 消费事件流，并按平台能力选择：
  - 原生 stream
  - 编辑消息
  - 多条短消息降级
- 阶段结束时至少有一条可验证主路径能做到“不是一次性整段发完”，并且 contract 已能支撑后续平台扩展。

## 开工前必须先看的代码路径

- `lib/nex/agent/llm/req_llm.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/tool/message.ex`
- `lib/nex/agent/channel/telegram.ex`
- `lib/nex/agent/channel/discord.ex`
- `lib/nex/agent/channel/slack.ex`
- `lib/nex/agent/channel/feishu.ex`
- `lib/nex/agent/channel/dingtalk.ex`
- `test/nex/agent/inbound_worker_test.exs`
- `test/nex/agent/llm/req_llm_test.exs`

外部能力边界先看：

- [2026-04-16 IM Streaming Capabilities And Delivery Contract](../findings/2026-04-16-im-streaming-capabilities.md)

## 固定边界 / 已冻结的数据结构与 contract

本 phase 固定以下边界。

1. 主链统一交付对象冻结为“事件流”，不是 `String.t()`。
2. 第一版统一事件 struct 固定为：

```elixir
%Nex.Agent.Stream.Event{
  seq: pos_integer(),
  run_id: String.t(),
  type:
    :message_start
    | :text_delta
    | :text_commit
    | :tool_call_start
    | :tool_call_result
    | :tool_call_end
    | :message_end
    | :error,
  content: String.t() | nil,
  name: String.t() | nil,
  tool_call_id: String.t() | nil,
  data: map()
}
```

3. 第一版 stream result struct 固定为：

```elixir
%Nex.Agent.Stream.Result{
  handled?: boolean(),
  run_id: String.t(),
  status: :ok | :error,
  final_content: String.t() | nil,
  error: term() | nil,
  metadata: map()
}
```

字段语义冻结：

- `handled?: true` 表示用户可见交付已经由 stream transport 负责，`InboundWorker` 不得再默认 `publish_outbound/2`。
- `handled?: false` 只允许非 streaming fallback 使用。
- `status: :error` 表示错误已经转成 `Nex.Agent.Stream.Event{type: :error}` 并交给 transport。
- `final_content` 只用于 session/history/audit 内部收尾，不作为默认 outbound 依据。

4. streaming 主路径返回 contract 固定为：

```elixir
{:ok, %Nex.Agent.Stream.Result{handled?: true} = result, session}
| {:error, %Nex.Agent.Stream.Result{handled?: true, status: :error} = result, session}
```

`Nex.Agent.prompt/3` 与 `agent_prompt_fun` 必须原样保留这个 result shape。不得把 streaming result 压平成 string 或普通 atom。

5. 第一版 stream sink contract 固定为：

```elixir
@callback handle_event(Nex.Agent.Stream.Event.t(), state :: term()) ::
            {:ok, term()}
            | {:error, term()}
```

6. `Runner` 与 `InboundWorker` 之间新增的上行接口必须允许“持续推送事件”。
   - 不允许把 callback contract 继续限定为 `fn(type, text) -> :ok end`
   - 允许内部先用 callback 落地，但 callback 的输入必须是统一 event struct
7. channel transport 能力分层冻结为：
   - `:native_stream`
   - `:edit_message`
   - `:multi_message`
8. 第一版平台能力判定来源冻结为：
   - 外部官方资料：见 findings
   - Feishu / DingTalk 暂以仓库现实现状作为执行边界，未确认的外部能力不在本 phase 假定存在
9. 第一版不追求“所有平台都完成流式正文”。
   - 先打通统一事件主链
   - 再优先让 Feishu 这条 edit-message 平台落地
   - Slack native-stream adapter 只有在底层接口补齐后才进入 blocking 主线
10. 不允许为某个平台单独发明一套旁路 callback 协议。
   - 所有平台都必须消费同一种 `Nex.Agent.Stream.Event`
11. 不允许把 tool progress 混入 assistant 最终正文持久化文本。
12. 第一条 edit-message 主路径冻结为 Feishu。
    - Telegram / Discord 不作为本 phase 默认首选验证路径
13. streaming 主路径下，`Runner` / `Nex.Agent.prompt/3` / `agent_prompt_fun` 的最终返回值冻结为“内部收尾值”，不是默认用户可见最终回复。
14. `InboundWorker.handle_info({:async_result, ...})` 在 streaming 主路径下不得再调用默认 final outbound。
    - 最终用户可见 closeout 由 transport session 在 `:message_end` 后负责
    - 判定条件固定为 result match `%Nex.Agent.Stream.Result{handled?: true}`
    - 不能依赖 payload metadata、自由 map、或 magic string 判断是否 suppress
15. streaming 错误路径 contract 固定为：
    - `Runner` 或 transport 捕获到 streaming 错误时，必须先发送 `Nex.Agent.Stream.Event{type: :error}`。
    - `Runner` 返回 `{:error, %Nex.Agent.Stream.Result{handled?: true, status: :error}, session}`。
    - `Nex.Agent.prompt/3` 和 `agent_prompt_fun` 不得把该 result 变成 `"Error: ..."` 字符串。
    - `InboundWorker.handle_info({:async_result, {:error, result, updated_agent}, payload})` 若 result 是 `%Stream.Result{handled?: true}`，不得默认 `publish_outbound(payload, "Error: ...")`。
    - `InboundWorker.handle_info({:async_result, {:error, result}, payload})` 若 result 是 `%Stream.Result{handled?: true}`，同样不得默认 `publish_outbound(payload, "Error: ...")`。
16. 旧 `on_progress` tuple contract 只允许作为过渡 wrapper。
    - Stage 2 结束后主链正式接口必须只使用统一 event struct

## 执行顺序 / stage 依赖

- Stage 1: 建立统一事件流 contract
- Stage 2: 让 Runner 主链产出事件流
- Stage 3: 建立 channel transport 抽象与能力协商
- Stage 4: 接入 Feishu edit-message 主路径
- Stage 5: 补 Slack native-stream adapter，并在接口就绪后再接 transport
- Stage 6: 补齐降级路径、回归测试与 reviewer 检查点

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1。  
Stage 4 依赖 Stage 2 和 Stage 3。  
Stage 5 依赖 Stage 3。  
Stage 6 依赖 Stage 4 和 Stage 5。  
当前主线从 Stage 1 开始。

## Stage 1

### 前置检查

- 确认 findings 中的平台能力来源已经可供 reviewer 核对。
- 确认 `ReqLLM.stream/3` 的 callback 输出已经能区分文本增量、tool call、完成事件。
- 确认现有 `on_progress` 使用点不会误被继续当成正式 streaming contract。

### 这一步改哪里

- 新增 `lib/nex/agent/stream/event.ex`
- 新增 `lib/nex/agent/stream/result.ex`
- 新增 `lib/nex/agent/stream/sink.ex`
- 需要时新增 `lib/nex/agent/stream.ex`
- 更新 `lib/nex/agent/runner.ex`
- 更新 `lib/nex/agent/inbound_worker.ex`
- 新增 `test/nex/agent/stream_test.exs`

### 这一步要做

- 定义 `Nex.Agent.Stream.Event` struct。
- 定义 `Nex.Agent.Stream.Result` struct。
- 定义 `Nex.Agent.Stream.Sink` behaviour。
- 定义统一事件序号规则：
  - 同一 `run_id` 内严格递增
  - 不允许不同 event 复用同一 `seq`
- 定义第一版事件映射规则：
  - assistant 第一段输出前发 `:message_start`
  - 文本增量发 `:text_delta`
  - 可见文本完成并决定 transport flush 时发 `:text_commit`
  - tool 调用开始发 `:tool_call_start`
  - tool 调用结果摘要发 `:tool_call_result`
  - tool 调用结束发 `:tool_call_end`
  - assistant 正文结束发 `:message_end`
  - 失败发 `:error`
- 把 `InboundWorker` 的进度接口升级为接收统一 event，而不是 `{:tool_hint, text}` / `{:thinking, text}` 这种 ad-hoc tuple。
- 冻结 streaming 主路径下的返回值边界：
  - `Runner` 最终返回 `%Nex.Agent.Stream.Result{handled?: true}` 用于 session/state 持久化和 outbound suppress 判定
  - 但该结果不再自动等价于“应该发给用户的最终消息”
- 冻结 `InboundWorker.handle_info({:async_result, ...})` 的分流规则：
  - 非 streaming 路径：保持现有 final outbound 语义
  - streaming success 路径：如果 result match `%Nex.Agent.Stream.Result{handled?: true}`，不得默认 `publish_outbound(payload, result)`
  - streaming error 路径：如果 reason/result match `%Nex.Agent.Stream.Result{handled?: true, status: :error}`，不得默认 `publish_outbound(payload, "Error: ...")`
  - streaming 路径最终收尾由 transport session 在 `:message_end` 处理
- 冻结 `InboundWorker` suppress helper：

```elixir
suppress_outbound?(%Nex.Agent.Stream.Result{handled?: true}), do: true
suppress_outbound?(_), do: existing_non_streaming_rules
```

- 冻结 streaming error event 规则：
  - 任何 streaming error 都必须先发 `Nex.Agent.Stream.Event{type: :error, content: format_reason(reason), data: %{reason: inspect(reason)}}`
  - 发送 error event 成功或已交给 transport 后，返回 `%Stream.Result{handled?: true, status: :error}`
  - 如果连 error event 都无法交给 transport，才允许 fallback 到非-streaming error outbound

### 实施注意事项

- Stage 1 只冻结 contract，不要求直接把所有 channel 接上。
- `:text_commit` 不能等价于“最终完成”；它只表示当前 transport 应该把累计文本落到用户可见面。
- 不要在 event struct 里直接塞平台专属字段。
- `data` 可以承载 provider/model/finish_reason 等扩展字段，但主路径判断不能依赖自由拼 map。
- `handled?: true` 是唯一正式 suppress final outbound 的 streaming sentinel。
- 不允许用 `:message_sent`、`"_streaming" => true`、payload metadata 或 string prefix 当 streaming suppress contract。
- 这一 stage 必须把“用户可见消息发送”和“内部返回值”两个语义拆开，不允许继续模糊共用。

### 本 stage 验收

- 仓库里存在统一事件流 contract，而不是多种 callback 口子并存。
- `Runner` / `InboundWorker` 能在测试里用同一类 event 交互。
- reviewer 能直接看到 stage 后续都围绕同一个 struct/behaviour 推进。
- reviewer 能直接看到 streaming 路径不会在结尾再走一次默认 final outbound。
- reviewer 能直接看到 `InboundWorker` 用 `%Nex.Agent.Stream.Result{handled?: true}` 判定 suppress，而不是现场发明 sentinel。
- streaming error 已有明确 result contract，不会额外再发一条默认 error 文本。

### 本 stage 验证

- 新增单测覆盖：
  - event struct 基本字段
  - stream result struct 基本字段
  - seq 递增规则
  - sink callback contract
  - `suppress_outbound?/1` 对 `%Stream.Result{handled?: true}` 返回 true
  - streaming error result suppresses default error outbound
- 运行：
  - `mix test test/nex/agent/stream_test.exs`

## Stage 2

### 前置检查

- Stage 1 的事件 contract 已固定。
- `ReqLLM.stream/3` 的输出格式已读清楚。
- 明确 `Runner` 当前 `handle_response/9` 仍是完整响应式处理。

### 这一步改哪里

- `lib/nex/agent/llm/req_llm.ex`
- `lib/nex/agent/runner.ex`
- 需要时新增 `lib/nex/agent/stream/assembler.ex`
- 更新：
  - `test/nex/agent/llm/req_llm_test.exs`
  - `test/nex/agent/inbound_worker_test.exs`
  - 需要时新增 `test/nex/agent/runner_stream_test.exs`

### 这一步要做

- 给 `Runner` 增加 streaming 主路径：
  - 有 stream sink 时优先走 `ReqLLM.stream/3`
  - 无 stream sink 时保留当前整轮 `chat` fallback
- 把 LLM stream chunk 映射到统一 event：
  - 文本增量
  - tool call 组装
  - finish / error
- `Runner` 内部仍然要维护最终 session history。
  - 也就是“对外是增量事件流，对内仍能落完整 assistant/tool turn”
- `Runner` 在 tool round 之间必须显式发送边界事件，避免 transport 把工具前文本和工具后文本糊成一条不可控消息。
- 把旧 `on_progress` 路径收敛为兼容 wrapper：
  - 允许 `build_progress_callback/2` 暂时存在
  - 但它只能消费统一 event 再转旧 UI 表现
  - `Runner` 主链不得继续直接生产旧 tuple contract

### 实施注意事项

- 不要因为接 streaming 就破坏现有 tool loop。
- tool call 参数可能是逐步拼起来的，不能假设第一次 chunk 就完整。
- `ReqLLM.chat/2` fallback 仍要保留，避免一次把所有 provider 都绑死在 stream 能力上。
- session history 的 assistant content 必须是最终可见文本，不包含 thinking tag 或 transport marker。
- Stage 2 结束后，主链不允许同时存在：
  - 一套统一 event 正式接口
  - 一套 `{:tool_hint, text}` / `{:thinking, text}` 正式接口
  旧 tuple 只能作为 wrapper，不是新的主 contract。

### 本 stage 验收

- `Runner` 在测试里能持续产出 `Nex.Agent.Stream.Event`。
- `Runner` 在 streaming success 时返回 `{:ok, %Nex.Agent.Stream.Result{handled?: true, status: :ok}, session}`。
- `Runner` 在 streaming error 时先发送 `:error` event，再返回 `{:error, %Nex.Agent.Stream.Result{handled?: true, status: :error}, session}`。
- tool 调用轮次前后存在明确事件边界。
- 不启用 stream sink 时，旧的最终回复路径仍然可用。
- 启用 stream sink 时，不会在任务结束后再额外给用户发一整段重复答案。
- 启用 stream sink 且发生错误时，不会在事件流错误之外再额外发一条默认 `Error: ...` 文本。

### 本 stage 验证

- 新增或更新测试覆盖：
  - `ReqLLM.stream/3` 到统一 event 的映射
  - tool call 边界事件
  - chat fallback 与 stream 主路径并存
  - streaming success suppresses default final outbound
  - streaming error emits one `:error` event and suppresses default error outbound
- 运行：
  - `mix test test/nex/agent/llm/req_llm_test.exs`
  - `mix test test/nex/agent/runner_stream_test.exs`

## Stage 3

### 前置检查

- Stage 2 已经让 `Runner` 能产出统一 event。
- findings 中的平台能力分层已可引用。
- 当前各 channel 还没有统一 transport 抽象。

### 这一步改哪里

- 新增 `lib/nex/agent/channel/transport.ex`
- 需要时新增：
  - `lib/nex/agent/channel/transport/session.ex`
  - `lib/nex/agent/channel/transport/capability.ex`
- 更新：
  - `lib/nex/agent/inbound_worker.ex`
  - `lib/nex/agent/channel/slack.ex`
  - `lib/nex/agent/channel/telegram.ex`
  - `lib/nex/agent/channel/discord.ex`
  - `lib/nex/agent/channel/feishu.ex`
  - `lib/nex/agent/channel/dingtalk.ex`
- 新增 `test/nex/agent/channel_transport_test.exs`

### 这一步要做

- 定义统一 transport capability 查询接口。
- 定义 transport session state，至少包含：
  - 当前 transport strategy
  - 已发送 carrier id
  - 当前累计可见文本
  - 上次 flush 时间
- 把平台适配从“直接发字符串”升级为“消费事件流并输出平台动作”。
- 第一版 transport strategy 选择规则固定为：
  - Feishu: `:edit_message`
  - Slack: `:native_stream` candidate，仅在 adapter 落地后启用
  - Telegram: `:edit_message` candidate，不作为本 phase 首选落地路径
  - Discord: `:edit_message` candidate，不作为本 phase 首选落地路径
  - DingTalk: `:multi_message`

### 实施注意事项

- 这里的 `:edit_message` 是 transport 抽象名，不要求底层 API 名字也叫 edit。
- Feishu 卡片 PATCH 可归到 `:edit_message` 能力层，不要单独再发明 `:patch_card` 顶层策略。
- `:multi_message` 平台必须有节流规则，不能对每个 token 发一条。
- transport 不能把 tool progress 混成 assistant 最终 message content。
- Stage 3 只冻结 capability 和 transport contract，不要求 Telegram / Discord / Slack 在这一 stage 就补完底层 adapter。

### 本 stage 验收

- `InboundWorker` 不再只知道“最后 publish_outbound 一次”，而是能驱动 transport session。
- 每个平台的发送策略选择在一个地方可见、可测。
- reviewer 能直接看到平台能力协商不是散落在 channel 文件里。
- reviewer 能直接看到 Feishu 是第一条 edit-message 主路径，而 Telegram / Discord / Slack 只是候选能力，不是当前默认首选。

### 本 stage 验证

- 新增测试覆盖：
  - capability -> strategy 选择
  - transport session 状态推进
  - tool 边界导致 segment flush
- 运行：
  - `mix test test/nex/agent/channel_transport_test.exs`

## Stage 4

### 前置检查

- Stage 3 的 transport 抽象已稳定。
- Feishu 当前仓库已有 carrier id + update 能力。
- 已冻结“第一条 edit-message 主路径优先选 Feishu”。

### 这一步改哪里

- `lib/nex/agent/channel/feishu.ex`
- 更新：
  - `lib/nex/agent/inbound_worker.ex`
  - 相关 channel tests

### 这一步要做

- 先打通 Feishu edit-message transport。
- Feishu 编辑型平台的基本策略固定为：
  - 首次可见文本先创建 carrier
  - 后续增量按节流策略更新同一 carrier
  - tool 边界时结束当前 segment
  - tool 后新的 assistant 文本进入新的 segment 或新的 carrier

### 实施注意事项

- 这一 stage 不引入 Telegram / Discord / Slack 作为主验证路径。
- Feishu transport 必须复用现有 card id / PATCH 主链，不要绕开现有能力重造 carrier 体系。
- 编辑型平台必须保存 message id / ts / card id 等 carrier 标识。

### 本 stage 验收

- Feishu 路径能做到持续增量输出，而不是最终一次性发整段。
- 工具调用前后不会把所有文本糊进同一段消息里。

### 本 stage 验证

- 新增或更新测试覆盖：
  - Feishu transport 的创建/更新/结束
  - tool 边界切段
- 运行：
  - 对应最小 channel test 子集

## Stage 5

### 前置检查

- Stage 3 的 transport 抽象已稳定。
- Slack 外部资料已确认原生 stream API。
- 当前仓库仍没有 Slack stream adapter 落点。

### 这一步改哪里

- `lib/nex/agent/channel/slack.ex`
- 需要时新增：
  - `lib/nex/agent/channel/slack/stream_client.ex`
  - 或等价的 Slack stream adapter 模块
- 更新相关测试

### 这一步要做

- 先补 Slack stream adapter / HTTP methods：
  - `chat.startStream`
  - `chat.appendStream`
  - `chat.stopStream`
- 冻结 adapter state 至少包含：
  - stream session identifier
  - append target identifier
  - stop/close 所需上下文
- 只有当 adapter 已落地且测试可跑后，Slack 才能进入 transport 主路径。

### 实施注意事项

- 这一 stage 的目标是“补底层能力入口”，不是顺手完成所有 Slack transport UX。
- 如果 adapter 未落地完成，后续 stage 不得把 Slack 当作唯一 blocking 主线。
- Slack native-stream 与 `chat.update` 路径不能混成同一套假接口。

### 本 stage 验收

- 仓库中存在明确的 Slack stream adapter 落点，而不只是 findings 里写“外部支持”。
- reviewer 能看到 `chat.startStream` / `appendStream` / `stopStream` 的实际入口和测试。

### 本 stage 验证

- 新增或更新测试覆盖：
  - Slack stream adapter start / append / stop
- 运行：
  - 对应 Slack 最小 test 子集

## Stage 6

### 前置检查

- Stage 4 已经打通 Feishu edit-message。
- Stage 5 已经补齐 Slack stream adapter。
- 统一事件流 contract 没有继续漂移。

### 这一步改哪里

- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/channel/slack.ex`
- `lib/nex/agent/channel/dingtalk.ex`
- 需要时更新：
  - `lib/nex/agent/channel/http.ex`
  - `lib/nex/agent/channel/telegram.ex`
  - `lib/nex/agent/channel/discord.ex`
  - 相关测试
- 更新文档：
  - `docs/dev/findings/index.md`
  - `docs/dev/task-plan/index.md`

### 这一步要做

- 在 Slack adapter 就绪后接入 Slack native-stream transport。
- 给 `:multi_message` 平台补齐降级策略。
- 明确 flush / debounce / segment 边界规则。
- 回收旧的 ad-hoc progress 发送口，避免双轨并存。
- 补齐 reviewer 检查点：
  - 外部资料与 capability 选择一致
  - 平台 transport 与 findings 没有自相矛盾
  - fallback 行为在测试里可见

### 实施注意事项

- `:multi_message` 降级必须以“短句 / 片段”为单位，不是 token 级 spam。
- HTTP channel 如果继续保留“最终字符串”语义，也要先明确它是否在本 phase 内属于非目标路径。
- 这一 stage 要清掉明显多余的旧接口，不要让后续实现者继续踩双轨。
- Telegram / Discord 若要接入 edit-message，必须先各自补底层 update adapter，再进入主路径。

### 本 stage 验收

- 三类 transport 都有明确可执行路径：
  - `:native_stream`
  - `:edit_message`
  - `:multi_message`
- 统一事件流 contract 成为主链唯一增量接口。
- reviewer 能从 findings + phase plan + 测试直接核对平台能力、实现路径和降级行为。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/stream_test.exs`
  - `mix test test/nex/agent/runner_stream_test.exs`
  - `mix test test/nex/agent/channel_transport_test.exs`
  - 对应 channel test 最小子集

## Review Fail 条件

- 继续把“最终字符串”当作主接口，只在某个平台旁路加临时 callback。
- platform capability 选择与 findings 中记录的官方来源矛盾。
- 把 tool progress 当作 assistant 正文的一部分持久化给用户。
- 让 Slack 原生 stream 能力退化成只能 edit-message，却没有理由说明。
- 在 Slack adapter 还不存在时，就把 Slack 当作唯一 blocking 主验证路径。
- 在 Feishu 已有更新链路的前提下，仍把 Telegram / Discord 作为第一条 edit-message 主路径。
- 在未确认官方来源的前提下，把 Feishu / DingTalk 的未验证能力写成已冻结事实。
- 让阶段结束时仍然同时维护多套不兼容的增量输出协议。
