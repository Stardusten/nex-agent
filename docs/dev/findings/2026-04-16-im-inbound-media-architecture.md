# 2026-04-16 IM Inbound Media Architecture

## 结论

后续媒体主线不继续扩散在各 channel 的 `metadata["media"]` 私有结构里。

新的主线冻结为：

```text
IM raw event
-> Inbound envelope
-> media refs
-> hydrated local attachments
-> provider-native model input projection
-> LLM call
```

与现状相比，关键变化是：

- 媒体在进入模型前统一持久化成本地文件
- channel 只负责提取平台引用和下载 / hydrate
- `ContextBuilder` 不再识别平台私有 media map
- provider 适配层负责把 attachment 投影成 provider-native multimodal content
- vision / OCR / transcription 工具只作为 fallback，不再作为媒体主路径

## 为什么不继续沿用当前实现

当前仓库已有一条可工作的图片快速通道：

- Feishu / Telegram 在 channel 内把图片下载成 data URL
- data URL 塞进 `payload.metadata["media"]`
- `InboundWorker` 读出 `media`
- `ContextBuilder.build_user_content/2` 只认识 `type == "image"`
- `ReqLLM` 再把它转成 `ContentPart.image_url(url)`

这条路可以工作，但不是可扩展架构：

1. channel 私有 shape 直接泄漏到 prompt build 层。
2. 只支持 image，audio / video / file 没有位置。
3. data URL 不适合大文件，也不适合统一缓存和复用。
4. session history 只保存文本 prompt，不保存当前轮的 media 结构。
5. Discord 还没有接到这条链路上。

## 为什么不采用 Hermes 的“统一转工具摘要”方案

Hermes 的优点是：

- 入站媒体很早就落地成本地文件
- 出站媒体通过统一 send helpers 分派
- 平台差异主要收敛在 adapter

但 Hermes 的主路径并不保留 provider-native multimodal 输入：

- 图片默认通过 vision tool 生成文字摘要后再送模型
- 音频默认通过 STT 后送模型
- 这会丢失原始多模态输入能力

本仓库不采用这部分思路。

冻结结论：

- 保留 Hermes 的“先持久化成本地文件”前半段
- 不采用 Hermes 的“统一转工具摘要”后半段
- provider-native multimodal input 仍是主路径
- 工具分析只作为 fallback

## 冻结后的职责边界

### 1. Channel adapter

职责：

- 解析平台原始消息
- 产出统一 inbound envelope
- 提取媒体引用 `Media.Ref`
- hydrate 媒体到本地文件 `Media.Attachment`

不负责：

- 构造 LLM content part
- 决定 provider 是否支持该媒体类型
- 直接做 vision / STT / OCR 主路径

### 2. Inbound layer

职责：

- 承接 channel 产出的 envelope / attachment
- 把附件带入 `Runner`
- 保持 session routing、queue、streaming 开启逻辑不感知平台细节

不负责：

- 平台资源下载
- provider-specific content part 细节

### 3. Media layer

职责：

- 定义通用媒体引用和已落地附件结构
- 提供本地持久化目录与 metadata 读取 helper
- 提供 provider 投影输入

不负责：

- 平台消息发送 payload
- 卡片布局

### 4. Provider projection

职责：

- 将 `Media.Attachment` 投影为 provider-native multimodal input

第一版冻结目标：

- image -> native image input
- audio / video / file -> 保留 attachment metadata，并在 provider 不支持时明确降级

## 冻结的数据结构

### `Nex.Agent.Inbound.Envelope`

```elixir
%Nex.Agent.Inbound.Envelope{
  channel: String.t(),
  chat_id: String.t(),
  sender_id: String.t(),
  user_id: String.t() | nil,
  message_id: String.t() | nil,
  text: String.t(),
  message_type: atom(),
  raw: map(),
  metadata: map(),
  media_refs: [Nex.Agent.Media.Ref.t()],
  attachments: [Nex.Agent.Media.Attachment.t()]
}
```

说明：

- `text` 仍然是本轮 canonical 用户文本
- `media_refs` 是未 hydrate 前的平台资源引用
- `attachments` 是已落地本地文件后的统一媒体列表

### `Nex.Agent.Media.Ref`

```elixir
%Nex.Agent.Media.Ref{
  channel: String.t(),
  kind: :image | :audio | :video | :file,
  message_id: String.t() | nil,
  mime_type: String.t() | nil,
  filename: String.t() | nil,
  platform_ref: map(),
  metadata: map()
}
```

说明：

- `platform_ref` 保留 Feishu `image_key/file_key`、Telegram `file_id`、Discord attachment URL 等平台差异
- 该 struct 只用于 hydrate 前阶段，不进入 prompt build

### `Nex.Agent.Media.Attachment`

```elixir
%Nex.Agent.Media.Attachment{
  id: String.t(),
  channel: String.t(),
  kind: :image | :audio | :video | :file,
  mime_type: String.t(),
  filename: String.t() | nil,
  local_path: String.t(),
  size_bytes: non_neg_integer() | nil,
  source: :inbound | :generated | :downloaded,
  message_id: String.t() | nil,
  platform_ref: map(),
  metadata: map()
}
```

冻结规则：

1. `local_path` 在 attachment 阶段必须存在。
2. image / audio / video / file 都共用同一 attachment struct。
3. attachment 不允许直接携带 data URL 作为真相源。
4. 如需小图 data URL，只能在 provider projection 时临时生成，不写回 attachment。

## Provider projection contract

新增内部投影 helper，最小输出 shape 冻结为：

```elixir
%{
  type: :text | :image | :audio | :video | :file,
  attachment_id: String.t() | nil,
  content: term()
}
```

第一版最小行为冻结：

- image attachment：
  - 若 provider 支持 image input，则投影成原生 image content part
  - 若 provider 不支持，则生成确定性的 fallback text，不 silent drop
- audio / video / file attachment：
  - 第一版允许仅生成 fallback text
  - 但 attachment 结构必须完整传到 projection 层，不能在 channel 里提前丢掉

## 历史与记忆边界

当前 `Session.add_message(session, "user", prompt, ...)` 只保存文本 prompt。

冻结结论：

- 本次 phase5 不改 session persistence 格式
- attachment 只保证进入本轮 LLM request
- 如果后续需要在 session history 中持久化 attachment，另开后续 phase，不混入本轮

## 多渠道边界

架构必须从第一天按多渠道设计，但实现顺序冻结为：

1. Feishu first-path
2. Telegram second-path
3. Discord third-path

第一版实现时：

- phase5 必须把 struct / projector / hydrate contract 写成 channel-agnostic
- 但只要求 Feishu 全链落地
- Telegram / Discord 在 phase5 中只需要保持未来接入位置清晰，不要求同轮全做完

## 与出站链路的关系

入站和出站都共用 `Media.Attachment` 作为媒体真相源，但职责不同：

- 入站：
  - platform ref -> local attachment -> provider input
- 出站：
  - local/generated attachment -> platform send material

冻结结论：

- 先做入站 architecture 和 provider projection
- 再做 Feishu outbound format / media send
- 不反过来

## 后续执行指针

- 可执行实现放在 `docs/dev/task-plan/phase5-im-inbound-architecture-and-media-projection.md`
- Feishu outbound follow-up 放在 `docs/dev/task-plan/phase6-feishu-outbound-official-format-and-media-send.md`
