# 2026-04-17 Feishu Post, Interactive, And CardKit Rendering

## 结论

Feishu 出站文本需要避免“非流式一种协议、流式另一种协议”。`post + edit message` 曾被考虑作为统一 carrier，但真实 gateway 验证命中 Feishu 编辑次数上限：

- 错误码：`230072`
- 错误信息：`The message has reached the number of times it can be edited.`
- 发生场景：流式过程中多次 `PUT /im/v1/messages/{message_id}` 更新同一条 `post`

因此 `post + edit message` 不适合作为流式主路径。当前统一路线改为：

- 非流式：发送 `msg_type = "interactive"`，content 为 Card JSON 2.0。
- 流式：CardKit 创建同一套 Card JSON 2.0 卡片实体，发送 `interactive` card reference，后续更新 CardKit markdown element。

## Feishu 协议边界

### `post`

`post` 是 Feishu 富文本消息。当前统一文本 carrier 的最小 payload：

```json
{
  "msg_type": "post",
  "content": "{\"zh_cn\":{\"content\":[[{\"tag\":\"md\",\"text\":\"# Title\\n\\n> quote\"}]]}}"
}
```

它适合承载普通 markdown-like 文本，但不适合作为高频流式 carrier。真实验证显示，同一条 `post` 连续编辑会触发编辑次数上限。

### `interactive`

`interactive` 是消息卡片类型。OpenClaw 的非流式卡片使用 Card JSON 2.0：

```json
{
  "schema": "2.0",
  "config": {
    "width_mode": "fill"
  },
  "body": {
    "elements": [
      {
        "tag": "markdown",
        "content": "# Title\n\n> quote"
      }
    ]
  }
}
```

旧实现里混用了 `tag: "markdown"` 和 top-level `elements`，但没有 `schema: "2.0"` / `body.elements` 外壳。这会导致 Feishu 前端把部分 markdown 当普通文本显示，例如标题和引用。

### CardKit

CardKit 不是 IM 的另一个 `msg_type`，而是卡片实体 API。OpenClaw 流式卡片路线是：

1. `POST /cardkit/v1/cards` 创建 Card JSON 2.0 卡片实体，拿 `card_id`。
2. 发送一条 `msg_type = "interactive"` 消息引用该 `card_id`。
3. 后续通过 CardKit element update API 更新指定 `element_id` 的 markdown 内容。

CardKit 可以做更细粒度的卡片流式更新和交互。为了满足“流式/非流式同渲染”的约束，非流式也应统一使用 `interactive` Card JSON 2.0，而不是混用 `post`。

## OpenClaw 观察

OpenClaw 的实现不是单一协议：

- 普通文本默认走 `post`。
- 代码块/表格或配置要求卡片时走 `interactive` Card JSON 2.0。
- 流式走 `interactive` + CardKit。
- 表格有 `convertMarkdownTables` 文本转换入口，但没有证明它在 Feishu IM 中使用原生表格协议。
- 标题和引用没有额外原生映射，主要依赖 Feishu 对 markdown 的支持。

因此 OpenClaw 不能直接证明 `interactive` 可以稳定渲染所有 markdown；它更能证明的是“Card JSON 2.0 外壳必须正确”。

## 当前执行决策

当前阶段采用 `interactive JSON 2.0 + CardKit`：

- 普通 Feishu 文本发送 `interactive` Card JSON 2.0。
- Feishu stream session 使用 CardKit 创建 Card JSON 2.0 卡片实体。
- 初始 IM 消息发送 `{"type":"card","data":{"card_id":"..."}}` 的 `interactive` reference。
- 流式 delta/final update 使用 CardKit element content update 更新 `element_id = "content"`。
- `post + edit message` 仅保留为发现记录，不作为实现路线。

## 后续待验证

- 真实 Feishu 前端中 Card JSON 2.0 markdown component 对标题、引用、表格的渲染效果。
- CardKit element update 频控、错误形态、最终关闭 streaming mode 是否需要补齐。
- 如果 markdown table 仍不稳定，再决定是否为 Feishu JSON 2.0 实现原生 table component。
- `newmsg` 应在 transport/session 层拆分，不应侵入 message/outbound/tool 接口。
