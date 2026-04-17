# Phase 7 Feishu Streaming Converter Simplification

## 当前状态

- 当前 Feishu 出站和 streaming 已经落到 card JSON 2.0 / CardKit 主链。
- 但 streaming 主链上的中间抽象过多：
  - `Assembler`
  - `text_delta / text_commit / message_end`
  - `Transport`
  - `Session`
  - `action`
  - `run_actions`
- 这些中间层没有简化 Feishu streaming，反而把真正的平台状态机问题拆散了。
- 当前已确认的用户侧故障：
  - `<newmsg/>` 经常先累积进一个活跃 card，结束后再拆
  - active card 切换时机不对
  - 实现者很难直接定位“当前活跃 card / sequence / pending buffer”状态

对应架构判断见：

- [2026-04-17 Feishu Streaming Converter Boundary](../findings/2026-04-17-feishu-streaming-converter-boundary.md)

## 完成后必须达到的结果

- Feishu streaming 主链重构为：

```text
LLM 文本流
-> Feishu 有状态转换器
-> 飞书 API
```

- `Feishu` 转换器直接消费文本流，不再依赖当前多余的 streaming 中间事件/动作抽象解释正文边界。
- `<newmsg/>` 的行为改为：
  - 边界一出现，当前活跃 card 立即完成当前段
  - 后续内容立即切到新的活跃 card
  - 不允许“先累积到一个 card，结束后再拆”
- 当前多余的 streaming 中间抽象全部删除，不保留薄壳，不保留绕行层。
- 阶段结束时，飞书流式分消息必须可以在真实运行中正常使用。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/findings/2026-04-17-feishu-streaming-converter-boundary.md`
- `docs/dev/findings/2026-04-17-feishu-post-interactive-cardkit-rendering.md`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/stream/assembler.ex`
- `lib/nex/agent/stream/event.ex`
- `lib/nex/agent/stream/session.ex`
- `lib/nex/agent/stream/transport.ex`
- `lib/nex/agent/stream/feishu_session.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/channel/feishu.ex`
- `lib/nex/agent/channel/feishu/card_builder.ex`
- `test/nex/agent/channel_feishu_test.exs`
- `test/nex/agent/inbound_worker_test.exs`
- `test/nex/agent/stream/new_message_boundary_test.exs`
- `test/nex/agent/stream/streaming_config_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

本 phase7 固定以下边界。

1. 核心转换链路固定为：

```text
LLM 文本流
-> Feishu 转换器状态机
-> 飞书 API
```

2. 当前以下 streaming 中间抽象必须删除，不保留 repo 内部兼容层：
   - `Nex.Agent.Stream.Transport`
   - `Nex.Agent.Stream.Session` behaviour
   - `Nex.Agent.Stream.FeishuSession`
   - `Nex.Agent.Stream.MultiMessageSession`
   - `Nex.Agent.Stream.Event`
   - `Nex.Agent.Stream.Assembler`
   - `TransportActions`

3. `Runner` 不再向 Feishu 主链输出 `text_delta / text_commit / message_end` 这类 repo 内部 streaming 事件。
   - Feishu 主链直接消费文本流。
   - 允许 `Runner` 保留 provider raw stream drain，但不再把正文转换职责委托给上述中间抽象。

4. Feishu 转换器最小内部状态冻结为：

```elixir
defmodule Nex.Agent.Channel.Feishu.StreamConverter do
  defstruct [
    :chat_id,
    :metadata,
    :active_card_id,
    :active_sequence,
    active_text: "",
    pending_buffer: "",
    in_code_block?: false,
    completed: false
  ]
end
```

5. Feishu 转换器最小公开接口冻结为：

```elixir
start(chat_id, metadata) :: {:ok, state} | {:error, term()}
push_text(state, text_chunk) :: {:ok, state} | {:error, term()}
finish(state) :: {:ok, state} | {:error, term()}
fail(state, message) :: {:ok, state} | {:error, term()}
```

约束：

- `push_text/2` 直接消费 LLM 文本增量
- `push_text/2` 内部直接调用飞书 API，不返回 action list
- `<newmsg/>` 增量识别和切 card 只允许在转换器内部实现

6. `<newmsg/>` 行为 contract 冻结为：

- 若当前不在 fenced code block 内，并且 `pending_buffer` 增量识别出完整 `<newmsg/>`
- 则：
  - 将边界前文本 flush 到当前活跃 card
  - 立刻创建新的活跃 card
  - 后续文本进入新的活跃 card
- 不允许把 `<newmsg/>` 原样显示给用户
- 不允许把所有段先堆到一个 card，结束后再拆

7. CardKit `sequence` 必须由转换器内部严格递增维护。
   - 不允许再用随机数
   - 不允许由其他层猜测 sequence

8. 本 phase7 只重构 Feishu streaming 主链。
   - 不同时重构 Telegram / Discord / Slack
   - 这些平台后续可照“平台转换器”模式各自实现

9. 本 phase7 不改：
   - `message` tool 对外 contract
   - phase5 inbound media contract
   - phase6 outbound attachment/materialize 主链

## 执行顺序 / stage 依赖

- Stage 1: 记录错误边界并冻结新转换器 contract
- Stage 2: 删除旧 streaming 中间抽象
- Stage 3: 落地 Feishu 流式转换器状态机
- Stage 4: 接回 Runner / InboundWorker 到新转换器
- Stage 5: 修正 `<newmsg/>`、sequence、真实流式切 card
- Stage 6: 文档、CURRENT、真实验收

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 2。  
Stage 4 依赖 Stage 3。  
Stage 5 依赖 Stage 4。  
Stage 6 依赖 Stage 5。

## Stage 1

### 前置检查

- 通读当前 streaming 主链：
  - `Runner`
  - `Assembler`
  - `Transport`
  - `FeishuSession`
  - `InboundWorker`
- 确认当前用户侧故障已经复现：
  - `<newmsg/>` 原样显示
  - `<newmsg/>` 结束后再拆
  - active card 切换时机错误

### 这一步改哪里

- `docs/dev/findings/2026-04-17-feishu-streaming-converter-boundary.md`
- `docs/dev/task-plan/phase7-feishu-streaming-converter-simplification.md`
- `docs/dev/progress/CURRENT.md`

### 这一步要做

- 记录当前 streaming 中间抽象为什么是错误边界。
- 冻结新转换器的状态字段、接口、`<newmsg/>` contract、sequence contract。
- 把“飞书流式分消息可以正常使用”写成 phase7 的硬验收条件。

### 实施注意事项

- 这一 stage 只写文档，不改实现。
- 所有表述必须避免“删除一层，换成另一层新抽象”的歧义。
- 必须明确：
  - 删除的是多余的 streaming 中间解释层
  - 保留的是“转换器直接消费文本流”的主模型

### 本 stage 验收

- phase7 文档已经能直接指导后续执行者删除旧抽象并重建主链。
- 文档中不存在“薄壳保留”“兼容保留”“先绕过再说”这类模糊说法。

### 本 stage 验证

- 人工通读 phase7 文档一遍，确认没有歧义。

## Stage 2

### 前置检查

- Stage 1 已冻结新转换器 contract。
- 已确认本 phase 不保留旧 streaming 中间抽象兼容层。

### 这一步改哪里

- 删除：
  - `lib/nex/agent/stream/assembler.ex`
  - `lib/nex/agent/stream/event.ex`
  - `lib/nex/agent/stream/session.ex`
  - `lib/nex/agent/stream/transport.ex`
  - `lib/nex/agent/stream/feishu_session.ex`
  - `lib/nex/agent/stream/multi_message_session.ex`
  - `lib/nex/agent/stream/transport_actions.ex`
- 更新：
  - `lib/nex/agent/runner.ex`
  - `lib/nex/agent/inbound_worker.ex`
  - 相关测试文件

### 这一步要做

- 直接删除上述 streaming 中间抽象。
- 用编译错误驱动全部调用点迁移，不保留 repo 内部 shim。
- `Runner` 与 `InboundWorker` 中所有依赖旧 event/session/action 的路径必须清干净。

### 实施注意事项

- 不允许保留“空壳 Transport”或“空壳 Session behaviour”。
- 删除顺序以编译通过为目标，不以最小 diff 为目标。
- 如果某个测试只是在验证旧抽象存在，应直接删或改写，不保留历史包袱。

### 本 stage 验收

- 仓库中不再存在旧 streaming 中间抽象模块。
- `Runner` / `InboundWorker` 中不再引用它们。

### 本 stage 验证

- `mix compile`
- `rg "Transport|Session|Assembler|Stream.Event" lib test`

应确认旧 streaming 中间主链已消失。

## Stage 3

### 前置检查

- Stage 2 编译已恢复。
- `Feishu` channel 仍然保留 card JSON 2.0 / CardKit API helper。

### 这一步改哪里

- 新增 `lib/nex/agent/channel/feishu/stream_converter.ex`
- 更新 `lib/nex/agent/channel/feishu.ex`
- 新增 `test/nex/agent/channel/feishu_stream_converter_test.exs`

### 这一步要做

- 落地 `Nex.Agent.Channel.Feishu.StreamConverter`。
- `start/2` 负责：
  - 创建初始 CardKit card
  - 发送 `interactive` card reference
  - 初始化 `active_card_id` / `active_sequence`
- `push_text/2` 负责：
  - 追加到 `pending_buffer`
  - 增量解析 fenced code block / `<newmsg/>`
  - flush 当前 card
  - 必要时立刻新建下一个 active card
- `finish/1` 负责：
  - flush 剩余 buffer
  - 标记 completed
- `fail/2` 负责：
  - 把错误文本落到当前活跃 card 或新 card

### 实施注意事项

- 解析必须是增量的，不能重新扫描整条最终全文作为主逻辑。
- `<newmsg/>` 只在不在 fenced code block 时才切 card。
- `active_sequence` 必须严格递增。
- 飞书 API 调用失败时要返回显式错误，不要静默吞掉。

### 本 stage 验收

- `StreamConverter` 已经可以脱离 `Runner` 单独测试。
- `push_text/2` 能在增量输入下切出多个 active card。
- `sequence` 由 converter 内部维护。

### 本 stage 验证

- `mix test test/nex/agent/channel/feishu_stream_converter_test.exs`

## Stage 4

### 前置检查

- `StreamConverter` 已经单独可测。
- 旧 streaming 中间抽象已删除。

### 这一步改哪里

- `lib/nex/agent/runner.ex`
- `lib/nex/agent/inbound_worker.ex`
- 需要时更新 `lib/nex/agent.ex`
- 更新相关测试：
  - `test/nex/agent/inbound_worker_test.exs`
  - `test/nex/agent/channel_feishu_test.exs`

### 这一步要做

- 让 `Runner` 直接把 LLM 文本流交给 Feishu converter。
- `InboundWorker` 不再维护 stream session/action state machine。
- 飞书流式主链改成：

```text
InboundWorker
-> build Feishu converter
-> Runner 每个文本增量直接推给 converter
-> converter 自己调飞书 API
```

- 非 Feishu channel 暂不在这一 stage 重做，只清理被旧抽象强耦合的路径。

### 实施注意事项

- 不要在 `Runner` 里重建另一套假的 event system。
- Feishu converter 的实例生命周期要和当前 run 绑定。
- 这一 stage 的目标是主链跑通，不是同时做 Telegram/Discord 新实现。

### 本 stage 验收

- `InboundWorker` 不再持有 `stream_sessions` 那套旧状态机语义。
- `Runner` 不再给 Feishu 主链发 `text_delta / text_commit / message_end` 解释事件。

### 本 stage 验证

- `mix test test/nex/agent/inbound_worker_test.exs test/nex/agent/channel_feishu_test.exs`

## Stage 5

### 前置检查

- 新主链已能真实跑起来。
- `StreamConverter` 已接到 `Runner` 文本流。

### 这一步改哪里

- `lib/nex/agent/channel/feishu/stream_converter.ex`
- `test/nex/agent/channel/feishu_stream_converter_test.exs`
- `test/nex/agent/channel_feishu_test.exs`

### 这一步要做

- 把 `<newmsg/>` 行为打磨到真实可用：
  - 边界前内容更新当前 active card
  - 边界一到立即创建新 active card
  - 后续文本继续流进新 card
  - 不允许结束后再拆
- 修正 sequence 递增、空 segment、代码块内 `<newmsg/>`、连续 `<newmsg/>` 等边界。

### 实施注意事项

- 这一 stage 的判断标准是用户可见行为，不是测试好看。
- 不允许 fallback 到“先全文再拆”。
- 不允许把 `<newmsg/>` 原样显示给用户。

### 本 stage 验收

- 飞书流式分消息可以正常使用。
- 具体定义：
  - 一条回复里出现多个 `<newmsg/>`
  - 飞书前端能看到多个 card 按顺序流式出现
  - 不会先全部累积到一个 card 里
  - 不会结束后重复拆分
  - 不会把 `<newmsg/>` 原样显示出来

### 本 stage 验证

- 自动：
  - `mix test test/nex/agent/channel/feishu_stream_converter_test.exs`
  - `mix test test/nex/agent/channel_feishu_test.exs`
  - `mix test test/nex/agent/inbound_worker_test.exs`
- 手动真实验收：
  - 启动 gateway
  - 对飞书发送包含多个 `<newmsg/>` 的请求
  - 观察是否边流式边切出多个 card

## Stage 6

### 前置检查

- Stage 5 的自动测试和真实验收都通过。

### 这一步改哪里

- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/2026-04-17.md`
- `docs/dev/task-plan/index.md`
- 需要时更新 findings 索引

### 这一步要做

- 更新 CURRENT，把 phase7 设为当前主线。
- 记录 phase7 已删除的旧抽象和新主链。
- 记录真实验收结果与残余风险。

### 实施注意事项

- 文档里要明确写“旧 streaming 中间抽象已删除”。
- 不要把 phase7 混写进 phase6。

### 本 stage 验收

- 后续执行者只看 `CURRENT.md` 就能知道 phase7 是当前主线。
- 索引文件都能指向 phase7。

### 本 stage 验证

- 人工检查：
  - `docs/dev/task-plan/index.md`
  - `docs/dev/progress/CURRENT.md`
  - `docs/dev/findings/index.md`

## Review Fail 条件

以下任一情况出现，本 phase 判定失败：

- 旧 streaming 中间抽象仍然保留为薄壳或兼容层
- Feishu 主链仍然依赖 `text_delta / text_commit / message_end` 作为核心转换语义
- `<newmsg/>` 仍然是结束后再拆，而不是边界到达就切 card
- `<newmsg/>` 在真实飞书前端仍会原样显示
- sequence 仍不是转换器内部单点维护
