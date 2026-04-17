# Phase 6 Feishu Outbound Official Format And Media Send

## 当前状态

- phase5 已落地新的媒体真相源：
  - `Nex.Agent.Inbound.Envelope`
  - `Nex.Agent.Media.Ref`
  - `Nex.Agent.Media.Attachment`
- 当前 Feishu 出站真实状态是：
  - 默认正文仍走 `interactive` message
  - `lib/nex/agent/channel/feishu.ex` 直接把字符串送进 `FeishuRenderer.render_card/1`
  - `Nex.Agent.Stream.FeishuSession` 的 send / patch / streaming 都复用同一个 card 渲染入口
  - `message` tool 已支持：
    - plain content
    - 显式 `msg_type + content_json`
    - `local_image_path`
  - 但媒体出站生命周期仍然散在 `message` tool 与 `channel/feishu.ex`：
    - 只有 image upload helper
    - 没有统一 outbound request shape
    - 没有 file/audio/media upload-send 主链
- phase6 的任务不是再讨论方向，而是把 Feishu outbound 改造成可扩展、可复用的真实生产主链。

## 完成后必须达到的结果

- Feishu 默认正文主路径继续保持“输入是字符串”，但内部 builder 和 send / patch / streaming 全部固定在官方 card JSON 2.0。
- Feishu 媒体出站主链固定为：

```text
message/tool/runtime request
-> Outbound.Message / Media.Attachment
-> Feishu outbound media materializer
-> upload(image/file)
-> native send payload(image/file/audio/media)
-> Feishu API
```

- 本地图片 / 文件 / 音频 / 视频至少都能通过统一 contract 进入 Feishu 出站链路。
- `message` tool 不再只认识 `local_image_path` 这个单点特判。
- Feishu channel 内不再长期保留“工具层一个参数、channel 里另一套上传 helper、renderer 再一套媒体判断”的分裂状态。

## 开工前必须先看的代码路径

- `docs/dev/findings/2026-04-16-im-inbound-media-architecture.md`
- `docs/dev/task-plan/phase5-im-inbound-architecture-and-media-projection.md`
- `docs/dev/progress/CURRENT.md`
- `lib/nex/agent/media/attachment.ex`
- `lib/nex/agent/channel/feishu.ex`
- `lib/nex/agent/im_ir/renderers/feishu.ex`
- `lib/nex/agent/stream/feishu_session.ex`
- `lib/nex/agent/tool/message.ex`
- `lib/nex/agent/outbound.ex`
- `test/nex/agent/channel_feishu_test.exs`
- `test/nex/agent/message_tool_test.exs`
- `test/nex/agent/im_ir/feishu_renderer_test.exs`

飞书官方参考：

- `https://open.feishu.cn/document/server-docs/im-v1/message/create`
- `https://open.feishu.cn/document/server-docs/im-v1/message/update`
- `https://open.feishu.cn/document/uAjLw4CM/ukTMukTMukTM/reference/im-v1/message/patch`
- `https://open.feishu.cn/document/server-docs/im-v1/image/create`
- `https://open.feishu.cn/document/server-docs/im-v1/file/create`
- `https://open.feishu.cn/document/uAjLw4CM/ukzMukzMukzM/feishu-cards/card-json-v2-structure`
- `https://open.feishu.cn/document/uAjLw4CM/ukzMukzMukzM/feishu-cards/card-json-v2-components/component-json-v2-overview`
- `https://open.feishu.cn/document/uAjLw4CM/ukzMukzMukzM/feishu-cards/card-json-v2-components/content-components/rich-text`
- `https://open.feishu.cn/document/uAjLw4CM/ukzMukzMukzM/feishu-cards/card-json-v2-components/content-components/table`

## 固定边界 / 已冻结的数据结构与 contract

本 phase6 固定以下边界。

1. 继续复用 phase5 的 `Nex.Agent.Media.Attachment` 作为媒体真相源。
   - 不重新发明 `local_image_path` / `local_file_path` 私有 map 作为长期主链
   - attachment 的真相字段仍是 `local_path`

2. 默认正文输出对调用方仍保持字符串 contract。
   - `Runner`
   - `Transport`
   - `message` tool plain content
   - 都不直接暴露 Feishu card JSON 给上层

3. Feishu 默认正文主路径固定为 card JSON 2.0。
   - send card
   - patch card
   - streaming card
   - 三者必须共用同一个 builder 入口

4. 显式 `msg_type + content_json` 继续保留。
   - 它是 Feishu native escape hatch
   - 但不是默认正文主路径

5. phase6 只做 Feishu outbound。
   - 不扩 Telegram / Discord / Slack / DingTalk parity

6. phase6 不改 session persistence format。
   - 不把 outbound attachment 写进 `Session.add_message/4`

7. phase6 不在 `message` tool 与 `channel/feishu.ex` 之间保留旧新双轨兼容层。
   - 删除旧参数后，用编译错误 / 测试错误驱动调用方迁移

8. phase6 的统一出站 request 最小 shape 冻结为：

```elixir
defmodule Nex.Agent.Outbound.Message do
  @enforce_keys [:channel, :chat_id]
  defstruct [
    :channel,
    :chat_id,
    :text,
    :native_type,
    :native_payload,
    attachments: [],
    metadata: %{}
  ]
end
```

约束：

- `text` 是默认正文输入
- `native_type/native_payload` 只用于显式原生消息
- `attachments :: [Nex.Agent.Media.Attachment.t()]`
- 一个 request 可以是：
  - 纯文本
  - 纯 native payload
  - 纯 attachment
  - 文本 + attachment companion send

9. Feishu 出站媒体 materialization 最小接口冻结为：

```elixir
defmodule Nex.Agent.Channel.Feishu.OutboundMedia do
  @spec materialize(
          [Nex.Agent.Media.Attachment.t()],
          keyword()
        ) ::
          {:ok, [map()]} | {:error, term()}
end
```

第一版 materialized shape 冻结为：

```elixir
%{
  kind: :image | :file | :audio | :video,
  msg_type: "image" | "file" | "audio" | "media",
  payload: %{"image_key" => "..."} | %{"file_key" => "..."},
  attachment: %Nex.Agent.Media.Attachment{}
}
```

10. Feishu media kind 到 native msg_type 的第一版映射冻结为：

```elixir
:image -> "image"
:file -> "file"
:audio -> "audio"
:video -> "media"
```

11. 第一版上传接口冻结为：

```elixir
upload image  -> /im/v1/images
upload others -> /im/v1/files
```

第一版允许：

- image 走 image upload + image send
- file/audio/video 共用 file upload
- audio/video 的 native send payload 先只保证 `file_key`
- caption / rich preview 不在第一版硬补

12. `<newmsg/>` 在 Feishu card JSON 2.0 下继续固定为 divider。
   - 不在 phase6 改成真多 card

## 执行顺序 / stage 依赖

- Stage 1: 冻结统一 outbound message / media materialization contract
- Stage 2: 固定 Feishu card JSON 2.0 builder 边界
- Stage 3: 接入 Feishu media upload/materialize 主链
- Stage 4: 改造 `message` tool 到 attachment-first contract
- Stage 5: 接入 channel send / patch / streaming 主链
- Stage 6: 测试、CURRENT、handoff

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1。  
Stage 4 依赖 Stage 1 和 Stage 3。  
Stage 5 依赖 Stage 2、3、4。  
Stage 6 依赖 Stage 2、3、4、5。

## Stage 1

### 前置检查

- 确认 phase5 已把 `Media.Attachment` 作为真实媒体真相源。
- 确认当前 Feishu 出站仍然没有统一 outbound request struct。
- 确认本 stage 不改任何 API 调用行为，只冻结边界。

### 这一步改哪里

- 新增 `lib/nex/agent/outbound/message.ex`
- 需要时新增 `lib/nex/agent/channel/feishu/outbound_media.ex`
- 更新：
  - `lib/nex/agent/tool/message.ex`
  - `test/nex/agent/message_tool_test.exs`

### 这一步要做

- 落地 `%Nex.Agent.Outbound.Message{}`。
- 冻结 `message` tool 输出到 channel 的最小内部形状。
- 把当前 `content/msg_type/content_json/local_image_path` 的散装语义映射到统一 request。
- 明确：
  - plain text 不是 native payload
  - native payload 不是 attachment
  - companion send 是一个 request 内的 delivery policy，不是调用方自己拆两次 channel send

第一版 helper 可以直接按下面签名落：

```elixir
@spec from_tool_args(map(), map()) ::
        {:ok, Nex.Agent.Outbound.Message.t()} | {:error, term()}
```

### 实施注意事项

- 本 stage 不开始写 upload 请求。
- 不要把 Feishu 私有 `image_key/file_key` 直接塞进 `Media.Attachment`。
- 不要保留 `local_image_path` 作为长期唯一媒体入口。

### 本 stage 验收

- reviewer 能直接看出出站主链的统一 request 边界。
- 后续 stage 不需要再在 `message` tool 与 channel 之间临时拼装散装参数。

### 本 stage 验证

- `mise exec -- mix test test/nex/agent/message_tool_test.exs`

## Stage 2

### 前置检查

- Stage 1 的 outbound request 已冻结。
- 读清 `Nex.Agent.IMIR.Renderers.Feishu.render_card/1`。
- 读清 `Nex.Agent.Stream.FeishuSession` 目前怎样 send / patch card。

### 这一步改哪里

- 新增 `lib/nex/agent/channel/feishu/card_builder.ex`
- 更新：
  - `lib/nex/agent/im_ir/renderers/feishu.ex`
  - `lib/nex/agent/channel/feishu.ex`
  - `lib/nex/agent/stream/feishu_session.ex`
  - `test/nex/agent/im_ir/feishu_renderer_test.exs`
  - `test/nex/agent/channel_feishu_test.exs`

### 这一步要做

- 把 card JSON 2.0 builder 从 channel send 逻辑里显式抽出来。
- 固定 send / patch / streaming 共用一个 builder 入口。
- 把当前 `render_card/1` 的产物 shape 明确升级到 card JSON 2.0 主结构，而不是继续让 channel 自己猜 card 包装。

第一版 builder 接口直接按下面落：

```elixir
defmodule Nex.Agent.Channel.Feishu.CardBuilder do
  @spec build(String.t(), keyword()) :: map()
end
```

card config 第一版冻结为：

```elixir
%{
  "type" => "card",
  "data" => %{
    "config" => %{
      "update_multi" => true,
      "streaming_mode" => true,
      "summary" => %{"content" => "..."}
    },
    "elements" => [...]
  }
}
```

如果 Feishu 当前实际接口仍要求 `interactive.content` 的老外壳包装，则该包装只能发生在 channel send 层；builder 返回值本身仍以 JSON 2.0 data 为真相源。

### 实施注意事项

- 不要把 send / patch / streaming 各写一套 builder。
- 不要把 IM IR parser 逻辑搬进 channel。
- `<newmsg/>` 继续降级成 divider，不扩 scope。

### 本 stage 验收

- Feishu 默认正文 card 渲染边界清晰。
- send / patch / streaming 共用一个 builder。
- channel 不再自己维护 card 元素散装拼接逻辑。

### 本 stage 验证

- `mise exec -- mix test test/nex/agent/im_ir/feishu_renderer_test.exs`
- `mise exec -- mix test test/nex/agent/channel_feishu_test.exs`

## Stage 3

### 前置检查

- Stage 1 outbound request 已冻结。
- 确认 phase5 的 `Media.Attachment.local_path` 已经是媒体真相源。
- 确认当前 Feishu 只有 `upload_local_image/2`，没有 file/audio/video 统一链路。

### 这一步改哪里

- 新增 `lib/nex/agent/channel/feishu/outbound_media.ex`
- 更新：
  - `lib/nex/agent/channel/feishu.ex`
  - `test/nex/agent/channel_feishu_test.exs`
  - `test/nex/agent/message_tool_test.exs`

### 这一步要做

- 新增统一媒体 materialization：
  - image attachment -> upload image -> `%{msg_type: "image", payload: %{image_key: ...}}`
  - file/audio/video attachment -> upload file -> `%{msg_type: ..., payload: %{file_key: ...}}`
- 把当前 `upload_local_image/2` 收敛进统一媒体层，不再作为唯一特判主链。

第一版接口和伪代码直接按下面落：

```elixir
def materialize(attachments, opts) do
  Enum.map(attachments, fn
    %Attachment{kind: :image} = attachment ->
      upload via /im/v1/images
      %{kind: :image, msg_type: "image", payload: %{"image_key" => image_key}, attachment: attachment}

    %Attachment{kind: kind} = attachment when kind in [:file, :audio, :video] ->
      upload via /im/v1/files
      %{kind: kind, msg_type: msg_type_for(kind), payload: %{"file_key" => file_key}, attachment: attachment}
  end)
end
```

### 实施注意事项

- 不要重新引入 data URL。
- 上传失败必须返回明确错误，不 silent drop。
- attachment 的 `platform_ref` 不回写 Feishu 出站 key。

### 本 stage 验收

- image/file/audio/video 都进入统一 materialization 主链。
- channel 内不再只有 image 一个上传 helper。

### 本 stage 验证

- `mise exec -- mix test test/nex/agent/channel_feishu_test.exs`
- `mise exec -- mix test test/nex/agent/message_tool_test.exs`

## Stage 4

### 前置检查

- Stage 3 已能 materialize attachment 到 native payload。
- 读清当前 `message` tool 的 `local_image_path` 逻辑。
- 确认本 stage 要删旧单点特判，而不是再套一层兼容。

### 这一步改哪里

- 更新 `lib/nex/agent/tool/message.ex`
- 需要时更新 `lib/nex/agent/context_builder.ex`
- 更新：
  - `test/nex/agent/message_tool_test.exs`

### 这一步要做

- 把 `message` tool 从 `local_image_path` 特判改成 attachment-first contract。
- 第一版参数冻结为：

```elixir
content
msg_type
content_json
attachment_paths
attachment_kinds
channel
chat_id
receive_id_type
```

其中：

- `attachment_paths :: [String.t()]`
- `attachment_kinds :: [String.t()]`
- 两者按 index 对齐

如果第一版为了降低调用成本保留单文件简写，也只能保留一种：

```elixir
attachment_path
attachment_kind
```

并且必须在内部立即归一化成 attachment 列表；不要再保留 `local_image_path` 特判主链。

### 实施注意事项

- 不新增兼容 shim 去维持旧 `local_image_path` 行为长期并存。
- plain text + attachment companion send 仍可保留，但必须走统一 request。
- native `msg_type + content_json` 不能被 attachment 链路污染。

### 本 stage 验收

- `message` tool 不再把 Feishu image upload 写死成单参数特判。
- 调用方已能用统一 attachment 参数触发 Feishu 媒体发送。

### 本 stage 验证

- `mise exec -- mix test test/nex/agent/message_tool_test.exs`

## Stage 5

### 前置检查

- Stage 2 card builder 已冻结。
- Stage 3 media materialization 已冻结。
- Stage 4 `message` tool 已切到统一 request。

### 这一步改哪里

- 更新 `lib/nex/agent/channel/feishu.ex`
- 更新 `lib/nex/agent/stream/feishu_session.ex`
- 需要时更新 `lib/nex/agent/outbound.ex`
- 更新：
  - `test/nex/agent/channel_feishu_test.exs`
  - `test/nex/agent/message_tool_test.exs`

### 这一步要做

- 把 Feishu channel send 主链拆成三种明确路径：
  - plain text default -> card builder -> interactive send
  - explicit native -> direct native send
  - attachments -> materialize -> native media send
- companion send 明确为：
  - 先 text/native
  - 再 attachment send
- `FeishuSession` 的 card patch 继续只负责默认正文 card，不接手 native media send。

可以直接冻结最小 dispatcher 形状：

```elixir
case outbound_message do
  %Outbound.Message{native_type: type, native_payload: payload} ->
    send native

  %Outbound.Message{attachments: attachments} when attachments != [] ->
    maybe send text companion
    materialize attachments
    send each native media payload

  %Outbound.Message{text: text} ->
    send card / patch card
end
```

### 实施注意事项

- 不把 card 内嵌媒体展示和 native media send 混成一条 contract。
- streaming card patch 不负责上传媒体。
- 当前阶段不要扩图片 caption / file caption 的跨平台统一语义。

### 本 stage 验收

- Feishu 出站主链职责清楚：
  - card builder
  - media materializer
  - native sender
- 默认正文与媒体发送不再互相污染。

### 本 stage 验证

- `mise exec -- mix test test/nex/agent/channel_feishu_test.exs`
- `mise exec -- mix test test/nex/agent/message_tool_test.exs`
- `mise exec -- mix test test/nex/agent/im_ir/feishu_renderer_test.exs`

## Stage 6

### 前置检查

- Stage 1-5 已全部落地。
- 确认 CURRENT 仍把 phase5 写成 active mainline；如果 phase6 开工条件已满足，要同步主线指针。

### 这一步改哪里

- 更新 `docs/dev/progress/CURRENT.md`
- 更新 `docs/dev/progress/2026-04-16.md`
- 需要时更新 `docs/dev/task-plan/index.md`

### 这一步要做

- 在 CURRENT 中把 phase5 标成已完成可继续维护的基础层。
- 明确 phase6 现在是下一个可执行主线。
- 记录 reviewer 最小命令：
  - Feishu card builder
  - Feishu media materialization
  - `message` tool attachment send

### 实施注意事项

- 不把 CURRENT 写成 changelog。
- 只保留后续 executor 接 phase6 所需最小上下文。

### 本 stage 验收

- 后续执行者能直接按 phase6 stage 顺序开工。
- reviewer 知道 phase6 的真实起点已经是 phase5 之后的 attachment-first 仓库状态。

### 本 stage 验证

- 人工检查：
  - `docs/dev/progress/CURRENT.md`
  - `docs/dev/task-plan/phase6-feishu-outbound-official-format-and-media-send.md`

## Review Fail 条件

- phase6 继续让 Feishu 媒体上传逻辑散落在 `message` tool、channel、renderer 三处各自演化。
- 为了过渡编译而保留 `local_image_path` 与新 attachment-first 主链长期并存。
- 默认正文主链不走统一 card JSON 2.0 builder。
- native media send 与 card patch/streaming 混成一条不可验证的隐式路径。
- phase6 文档没有写明从当前 phase5 仓库状态开工时，第一步改哪个模块、删哪条旧路径、如何验收、如何验证。
