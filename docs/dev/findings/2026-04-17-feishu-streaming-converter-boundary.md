# 2026-04-17 Feishu Streaming Converter Boundary

## 结论

当前 streaming 主链里的中间抽象已经偏离问题本身。

当前真正要解决的问题不是：

- 设计一套统一的 `text_delta / text_commit / message_end` 事件体系
- 设计一套统一的 transport action 体系
- 再让 Feishu 在这些中间层之后“适配”

当前真正要解决的问题是：

```text
LLM 吐出文本流
-> 有状态转换器
-> 飞书 API
```

也就是说，转换器应该直接消费 LLM 文本流，而不是在它前面再加一层“流式中间事件系统”。

## 为什么当前抽象不对

当前实现把主问题拆成了：

```text
provider raw delta
-> Assembler
-> text_delta / text_commit / message_end
-> Transport
-> Session
-> action
-> run_actions
-> Feishu API
```

这会带来 3 个问题：

1. 最关键的平台状态没有成为一等公民。
   - 当前活跃 card 是谁
   - 当前 card 已经发送到哪里
   - 当前 sequence 是多少
   - `<newmsg/>` 什么时候切到新 card

2. 中间抽象层重复解释同一份文本。
   - Assembler 理解一遍
   - Session 再理解一遍
   - finalize 再解释一遍

3. 平台特有状态被“通用事件”抹平后，复杂性反而从抽象缝隙里漏出来。

## 正确边界

正确边界不是“删除这一层，换成另一层新抽象”，而是让已经存在的转换器回到正确位置：

```text
LLM 文本流
-> 转换器（有状态）
-> 飞书 API
```

这里“转换器”才是核心。

对 Feishu 来说，转换器内部的最小状态应当直接围绕平台 carrier：

```elixir
%{
  active_card_id: String.t(),
  active_sequence: pos_integer(),
  active_text: String.t(),
  pending_buffer: String.t(),
  in_code_block?: boolean(),
  metadata: map()
}
```

最小职责：

- 接收新的文本增量
- 维护活跃 card
- 维护 sequence
- 增量识别 `<newmsg/>`
- 在边界出现时立刻切到新 card
- 直接落飞书 API 调用

## `text_delta` / `text_commit` 的判断

`text_delta` / `text_commit` 不是 LLM 原始语义，它们是当前 `Runner + Assembler` 人工合成的中间事件。

这类事件可以存在，但它们不应成为 Feishu streaming 设计的核心抽象。

尤其是 `<newmsg/>` 这种需求，本质上是：

- 在文本增量里做边界识别
- 一旦识别到边界，立刻切换活跃 carrier

这属于转换器内部状态机问题，不应继续依赖 finalize 阶段做“全文重放后拆分”。

## 重构方向

接下来的 streaming 重构应遵守以下边界：

1. 删除当前多余的 streaming 中间事件/动作解释层。
2. 保留最小必要的 stream source 接口，但不再让这些中间事件承担平台转换职责。
3. 让 Feishu 转换器直接消费文本流。
4. `<newmsg/>` 只在转换器内部处理，不再拖到 finalize。
5. 飞书流式分消息必须以“边界一到即切新 card”为验收条件。

## 对后续平台的意义

这不是“只能 Feishu 用”的思路。

可复用的是模式：

```text
LLM 文本流
-> 平台转换器（有状态）
-> 平台 API
```

不可强行共用的是平台内部 carrier 状态：

- Feishu: `card_id` / `sequence` / CardKit
- Telegram: `message_id` / edit message
- Discord: response token / followup message

因此后续平台可以复用“状态转换器”模式，但不应继续复用当前这套过度泛化的 streaming 中间抽象。
