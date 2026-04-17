# 2026-04-16 Streaming Architecture Convergence

## 结论

上面的 review 基本有道理，而且不是“偏好问题”，而是已经能从当前实现里看到边界开始变形。

当前 phase3 主链已经成立，尤其是下面三点是对的：

- 统一事件流和 `%Nex.Agent.Stream.Result{}` 已经把“用户可见交付”和“内部收尾值”拆开。
- `InboundWorker` 负责 session 生命周期、`Runner` 负责生产事件，这个大方向是成立的。
- Feishu 特化没有重新散落回 agent loop 主干。

但这版代码也已经出现了 4 个真实的结构挤压点，继续往 Slack native stream、Telegram/Discord edit adapter 扩展前，值得先做一次 phase3a 收敛。

## 现状判断

### 1. `Runner` 确实同时承担了 orchestration 和 stream protocol assembly

这个问题成立，而且比 review 里说的还更具体。

当前 `Runner` 除了 agent loop，还直接负责：

- streaming result 语义切换：`stream_result/4`
  - `lib/nex/agent/runner.ex:658`
- 对 `ReqLLM.stream/3` 回调协议做 receive/drain/assemble
  - `lib/nex/agent/runner.ex:1023`
  - `lib/nex/agent/runner.ex:1076`
  - `lib/nex/agent/runner.ex:1098`
- unified event 发射与 seq 生成
  - `lib/nex/agent/runner.ex:1142`
  - `lib/nex/agent/runner.ex:1169`
- consolidation 再复制一套近似的 stream drain
  - `lib/nex/agent/runner.ex:1422`
  - `lib/nex/agent/runner.ex:1449`

这会带来两个后果：

- conversation 主链和 consolidation 都依赖 `Runner` 内部的 callback 协议细节，`Runner` 不再只是 loop orchestrator。
- stream 组装状态通过 process dictionary 隐式维护 `seq` / `message_started`，可读性和可替换性都开始下降。

这里真正该抽出的，不只是“event emitter”，而是更底层的一层：

- `ReqLLM raw stream events`
- `assembled provider response state`
- `optional user-visible event emission`

这三件事应该能被同一套 assembler 驱动，而不是在 `Runner` 里复制两份 drain 状态机。

### 2. consolidation 现在复用了错误层级的抽象

review 说“技术上统一了，但边界未必自然”，这个判断成立。

consolidation 的目标是：

- 消费 provider stream
- 等 tool call 收敛
- 取最终 tool call / finish_reason / usage

它并不需要：

- `Stream.Event`
- transport session
- 用户可见增量 flush 语义

现在 consolidation 直接复用 `ReqLLM.stream/3` 的 callback 协议，然后在 `Runner` 里再手写一套 `drain_consolidation_stream_events/2`。这说明当前抽象缺的是“provider stream accumulator”，而不是所有场景都应该走“用户对话 streaming contract”。

更自然的层次应当是：

1. provider stream accumulator
2. conversation stream event adapter
3. transport delivery adapter

consolidation 应只停留在第 1 层。

### 3. `Transport` 现在还不是平台能力层，而是中心化 dispatcher

这点也成立，而且不止 `open_session/4` 一处。

当前平台细节仍然集中在两个地方：

- `Transport.open_session/4` 直接按 channel 分支，并直接调用 `Nex.Agent.Channel.Feishu.send_card/3`
  - `lib/nex/agent/stream/transport.ex:7`
- `InboundWorker.run_stream_actions/1` 再按 action shape 特判 `:update_card`
  - `lib/nex/agent/inbound_worker.ex:737`

这意味着：

- capability enum 虽然存在，但 transport 选择不是按 capability 或 implementation 做，而是按 channel 名字做。
- 平台副作用的创建和执行分散在 `Transport` 与 `InboundWorker` 两边。
- 后续每接一个“不是简单 publish”的平台，中心 dispatcher 都会继续膨胀。

真正自然的 transport 层，应该让实现模块自己决定：

- 是否支持该 channel / metadata
- 如何创建 initial carrier
- 如何把 event 转成平台动作
- 如何执行平台动作

协议入口层不应知道 Feishu card 是怎么开的，也不应知道 `update_card` 这种平台动作名。

### 4. `MessageSession` 的命名和 contract 都在泄漏“过渡态”

review 提到命名不自然，这个成立。

`MessageSession` 实际能力就是 `:multi_message` fallback：

- `lib/nex/agent/stream/message_session.ex:42`

但更深一层的问题是，这个模块和 `FeishuSession` 的并列方式，会让后续维护者误以为：

- 一个是“通用消息 session”
- 一个是“Feishu 特化 session”

实际上它们并不是同一层的命名：

- `FeishuSession` 是平台名
- `MessageSession` 是能力泛称

如果继续沿这个命名扩展，后面很容易出现：

- `SlackNativeStreamSession`
- `EditMessageSession`
- `MessageSession`

然后三者混在一起，层次会更乱。

phase3a 应把 `MessageSession` 明确改成能力导向命名，例如 `MultiMessageSession`。

### 5. streaming 栈内部还保留了过多旧 contract 兼容

这是 review 里没有点透，但当前实现已经出现的额外问题。

`Stream.Session.finalize_success/2` 现在接受：

- `%Nex.Agent.Stream.Result{}`
- `:message_sent`
- `String.t()`

见：

- `lib/nex/agent/stream/message_session.ex:71`
- `lib/nex/agent/stream/feishu_session.ex:81`

这会让新的 streaming session 层继续背负旧非流式返回值语义，导致内部边界始终不能收紧。

如果 phase3 已经冻结“streaming 主路径最终返回 `%Stream.Result{}`”，那 phase3a 应该顺势把 stream transport 内部 contract 收紧到：

- streaming path 只吃 `%Stream.Result{}`
- 非 streaming fallback 在 `InboundWorker` 边界转换

否则每加一个 transport implementation，都要重新兼容字符串 / `:message_sent` / result struct 三套语义。

## 额外判断

### 现在不适合做“大一统 transport framework”

需要收敛，但不需要一次性做成复杂框架。

phase3a 更合适做的是：

- 抽出 provider stream assembler
- 收紧 transport behaviour
- 清理命名和旧 contract 泄漏

而不是在这一轮同时引入：

- 大而全 registry
- 通用 capability negotiation engine
- 所有平台统一 edit/native stream 实现

这轮应该优先解决“层次不自然”和“技术债继续扩散”的问题。

### phase3a 应该是收敛，不是新功能 phase

phase3a 的目标不应是“再支持一个新平台”，而应是让后续平台接入不再把复杂度继续压回 `Runner` 和 `Transport` 中心分支。

因此 phase3a 完成标志应该是：

- `Runner` 不再自己维护两套 drain/assemble 状态机
- consolidation 不再走用户对话 event assembly
- `Transport` 不再直接写平台分支副作用
- `MessageSession` 更名为能力命名，并清掉内部旧返回值兼容

## 建议的 phase3a 边界

建议把 phase3a 冻结为三件事：

1. 抽出 `Nex.Agent.Stream.Assembler`
   - 单一职责：消费 `ReqLLM.stream/3` raw events，维护 assembled state
   - 可选地向外发 unified `Stream.Event`
   - conversation path 和 consolidation path 共用同一 assembler
2. 抽出真正的 transport implementation behaviour
   - `Transport` 只做入口和实现选择
   - Feishu initial carrier creation / update action execution 下沉到 Feishu transport implementation
   - multi-message fallback 作为独立 implementation
3. 清理命名和内部 contract
   - `MessageSession` -> `MultiMessageSession`
   - streaming transport finalize contract 收紧到 `%Stream.Result{}`
   - 非 streaming 兼容留在 `InboundWorker` 或更外层边界

## 不建议放进 phase3a 的内容

- 直接补完 Slack native stream
- 一次性重写所有 channel outbound topic
- 重做 `ReqLLM.stream/3` provider 适配层
- 把 memory/consolidation 机制整体改写

phase3a 应该服务于后续 phase4，而不是抢跑 phase4。
