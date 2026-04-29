# 2026-04-16 IM Streaming Capabilities And Delivery Contract

## 结论先放前面

- `nex-agent` 目前没有统一的“增量事件流”主链。
- `Nex.Agent.Turn.LLM.ReqLLM.stream/3` 已存在，但 `Runner` 主链仍走一次性 `chat` 返回，不会把模型增量直接交给 channel。
- 不同 IM 的能力边界不同，必须把“assistant 增量输出 contract”和“平台传输策略”拆开。
- 第一版统一抽象不应该绑定“同步返回值”或“回调风格”，而应该绑定“事件流语义”。
- 平台传输至少分三类：
  - 原生 stream API
  - 发送后编辑同一条消息
  - 多条短消息分段发送

## 仓库现状证据

### LLM 层已有 stream 入口，但主链没接上

- `ReqLLM.stream/3` 已实现：
  - [req_llm.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/llm/req_llm.ex#L73)
- `Runner` 仍通过 `call_llm_real/2 -> ReqLLM.chat/2` 获取整轮结果：
  - [runner.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/runner.ex#L824)
- `Runner.handle_response/9` 的入口仍以完整 `content + tool_calls` 为处理单位，不是消费增量事件：
  - [runner.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/runner.ex#L344)
  - [runner.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/runner.ex#L438)

### InboundWorker 现有 progress 不是 assistant 正文流

- 当前 `on_progress` 只用于 tool hint / thinking card：
  - [inbound_worker.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/inbound_worker.ex#L356)
- 最终回复仍然在 async task 完成后统一 outbound：
  - [inbound_worker.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/inbound_worker.ex#L84)

### 各 channel 当前实现

- Telegram 当前只有发送，不支持编辑主链：
  - [telegram.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/channel/telegram.ex#L399)
- Discord 当前只有发送，不支持编辑主链：
  - [discord.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/channel/discord.ex#L301)
- Slack 当前只有 `chat.postMessage` 发送主链：
  - [slack.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/channel/slack.ex#L283)
- Feishu 当前已经有“发送卡片 + PATCH 更新卡片”能力，但只用于特定路径：
  - [feishu.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/channel/feishu.ex#L104)
  - [feishu.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/channel/feishu.ex#L114)
  - [feishu.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/channel/feishu.ex#L264)
- DingTalk 当前实现只有普通发送主链：
  - [dingtalk.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/channel/dingtalk.ex#L242)

## 外部资料与能力边界

下面只记录本轮已经确认到官方文档的外部结论。没有官方入口的项不在这里冒充“已确认”。

### Telegram

结论：

- Telegram Bot API 支持 `sendMessage`。
- Telegram Bot API 支持 `editMessageText`。
- 所以 Telegram 适合走“先发一条，再编辑同一条”的模拟流式策略。
- Telegram 不存在面向 bot reply 的“原生 token stream”消息接口。

来源：

- Telegram Bot API `sendMessage`
  - https://core.telegram.org/bots/api#sendmessage
- Telegram Bot API `editMessageText`
  - https://core.telegram.org/bots/api#editmessagetext

### Discord

结论：

- Discord REST API 支持编辑已发送消息。
- Interaction 响应路径也支持编辑原始响应。
- 所以 Discord 适合走“创建消息后持续编辑”的模拟流式策略。
- Discord 普通消息接口不是原生 token stream。

来源：

- Discord Developer Docs `Edit Message`
  - https://discord.com/developers/docs/resources/message#edit-message
- Discord Developer Docs `Edit Original Interaction Response`
  - https://discord.com/developers/docs/interactions/receiving-and-responding#edit-original-interaction-response

### Slack

结论：

- Slack 既支持传统 `chat.update` 编辑消息，也已经提供原生 stream 方法：
  - `chat.startStream`
  - `chat.appendStream`
  - `chat.stopStream`
- 所以 Slack 是当前已确认平台里唯一明确具备“原生 stream 发送 API”能力的目标。
- 统一抽象不能只围绕“编辑消息”设计，否则会把 Slack 原生能力浪费掉。

来源：

- Slack `chat.update`
  - https://api.slack.com/methods/chat.update
- Slack `chat.startStream`
  - https://docs.slack.dev/reference/methods/chat.startStream/
- Slack `chat.appendStream`
  - https://docs.slack.dev/reference/methods/chat.appendStream/
- Slack `chat.stopStream`
  - https://docs.slack.dev/reference/methods/chat.stopStream/

## 参考实现证据

### hermes-agent 的做法值得借鉴，但不能直接照搬 transport

结论：

- `hermes-agent` 已经把“模型增量输出”和“平台发送”之间插入了统一 stream consumer。
- 它会根据平台能力决定是否做 progressive edits。
- 它显式避免在不支持 message editing 的平台上硬开 streaming，以免出现“partial 一条 + final 一条”的重复污染。

证据：

- 统一 stream consumer：
  - [stream_consumer.py](/Users/krisxin/Desktop/hermes-agent/gateway/stream_consumer.py)
- gateway 在平台能力允许时挂上 `stream_delta_callback`：
  - [run.py](/Users/krisxin/Desktop/hermes-agent/gateway/run.py#L8465)

## 对 nex-agent 的接口约束

基于上面的平台边界，第一版统一 contract 应满足：

1. 上层消费的是“事件流”，不是 `String.t()` 最终值。
2. 事件流必须能同时承载：
   - assistant 文本增量
   - 工具调用开始/结束
   - 工具输出摘要
   - 最终完成/失败
3. channel adapter 只负责把统一事件流映射到本平台支持的 transport：
   - Slack：优先原生 stream
   - Telegram / Discord：优先 edit-message
   - Feishu：优先 card patch
   - DingTalk：如果缺少稳定 edit API，则先走多条短消息降级
4. “是否流式”和“如何流式”必须分开：
   - 前者是 agent/runner 侧增量事件生产能力
   - 后者是 channel transport 侧能力协商

## 第一条可落地主线选择

基于“外部能力已确认”和“仓库现成入口”这两个条件，本轮执行优先级冻结为：

1. 第一条 `:edit_message` 主路径优先选 Feishu。
   - 原因：仓库里已经存在 carrier id + update 路径：
     - [feishu.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/channel/feishu.ex#L104)
     - [feishu.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/channel/feishu.ex#L114)
     - [feishu.ex](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/channel/feishu.ex#L264)
2. Telegram / Discord 虽然外部文档确认支持编辑消息，但仓库当前没有现成 update adapter。
   - 它们不应在第一条 edit-message 主路径里充当默认首选。
3. Slack 原生 stream API 虽然外部文档已确认存在，但仓库当前没有：
   - `chat.startStream`
   - `chat.appendStream`
   - `chat.stopStream`
     对应的 adapter / HTTP client / state 管理入口
4. 因此 Slack 不能在当前 phase 中充当唯一 blocking 主路径。
   - 如果 Slack adapter 尚未补齐，先以 Feishu edit-message 路径验证统一事件流 contract。

## 与现有最终 outbound 的替换边界

本轮执行时必须遵守以下替换边界：

1. streaming 主路径下，最终返回值仍然保留，但用途冻结为：
   - session/history 持久化
   - run state 收尾
   - 测试断言
   - 不再默认触发最终整段 outbound
2. 用户可见的最终收尾由 transport session 在收到 `:message_end` 后自行完成。
3. `InboundWorker.handle_info({:async_result, ...})` 在 streaming 主路径下不得再调用默认的 `publish_outbound(payload, result)` 发送完整答案。
4. 现有 `on_progress` tuple contract 只允许作为过渡兼容层存在。
   - Stage 2 结束后主链不得继续直接生产 `{:tool_hint, text}` / `{:thinking, text}` 作为正式接口。

## 本文没有确认到官方来源的项

- Feishu/Lark 通用消息编辑 API 的官方入口，本轮没有定位到足够稳定的官方页面。
- DingTalk 是否存在适合 bot reply 主链的稳定“编辑已发送消息”官方 API，本轮没有定位到足够稳定的官方页面。

这些项在实现前仍应继续补官方来源；在补齐前，plan 只能把它们当“仓库现状 + 待确认能力”，不能当已冻结的外部事实。
