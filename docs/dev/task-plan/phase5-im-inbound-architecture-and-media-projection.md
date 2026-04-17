# Phase 5 IM Inbound Architecture And Media Projection

## 当前状态

- 当前入站链路已经能把部分图片带进模型，但没有形成对称、可扩展的架构。
- 当前真实链路是：

```text
channel private normalize
-> payload.metadata["media"]
-> InboundWorker.extract_media/1
-> Runner opts[:media]
-> ContextBuilder.build_user_content/2
-> ReqLLM ContentPart.image_url(url)
```

- 该链路目前存在四个主要问题：
  - channel 私有 media map 泄漏到 prompt build 层
  - 实际只支持 image
  - 使用 data URL 作为主载体，不利于大文件和统一缓存
  - 没有像出站 `Transport/Session` 那样清晰的分层边界
- 用户已经冻结新方向：
  - 入站架构和媒体入站一起做
  - 架构按多渠道设计
  - 实现先只完整落地 Feishu
  - 先做好“媒体怎么进模型”
  - 出站媒体发送后移到下一个 phase

## 完成后必须达到的结果

- 仓库新增清晰的入站媒体主链：

```text
raw event
-> Inbound.Envelope
-> Media.Ref
-> hydrated Media.Attachment(local file)
-> provider-native model input projection
-> LLM request
```

- `ContextBuilder` 不再直接认识各 channel 私有 `metadata["media"]` shape。
- `Runner` / `ContextBuilder` 的媒体输入冻结为 `[Nex.Agent.Media.Attachment.t()]`。
- Feishu first-path 完整落地：
  - image message
  - post 内图片资源
  - file/audio/media 至少能产出 `Media.Ref`
  - image attachment 可稳定进入模型原生 image input
- phase5 结束时，仓库内“入站媒体如何进入模型”不再依赖 channel 私有 hacks。

## 开工前必须先看的代码路径

- `docs/dev/findings/2026-04-16-im-inbound-media-architecture.md`
- `docs/dev/progress/CURRENT.md`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/llm/req_llm.ex`
- `lib/nex/agent/channel/feishu.ex`
- `lib/nex/agent/channel/telegram.ex`
- `lib/nex/agent/channel/discord.ex`
- `test/nex/agent/channel_feishu_test.exs`
- `test/nex/agent/channel_telegram_test.exs`
- `test/nex/agent/context_builder_test.exs`
- `test/nex/agent/inbound_worker_test.exs`

飞书官方参考：

- `https://open.feishu.cn/document/server-docs/im-v1/message/create`
- `https://open.feishu.cn/document/server-docs/im-v1/image/create`
- `https://open.feishu.cn/document/server-docs/im-v1/file/create`
- `https://open.feishu.cn/document/uAjLw4CM/ukTMukTMukTM/reference/im-v1/message/patch`

## 固定边界 / 已冻结的数据结构与 contract

本 phase5 固定以下边界。

1. 不改 session persistence format。
   - 当前轮 attachment 进入模型即可
   - 不把 attachment 写进 `Session.add_message/4` 主格式

2. 入站主链统一由三个内部结构承接：
   - `Nex.Agent.Inbound.Envelope`
   - `Nex.Agent.Media.Ref`
   - `Nex.Agent.Media.Attachment`

最小代码 shape 冻结为：

```elixir
defmodule Nex.Agent.Inbound.Envelope do
  @enforce_keys [:channel, :chat_id, :sender_id, :text, :message_type, :raw, :metadata]
  defstruct [
    :channel,
    :chat_id,
    :sender_id,
    :user_id,
    :message_id,
    :text,
    :message_type,
    :raw,
    :metadata,
    media_refs: [],
    attachments: []
  ]
end

defmodule Nex.Agent.Media.Ref do
  @enforce_keys [:channel, :kind, :platform_ref]
  defstruct [
    :channel,
    :kind,
    :message_id,
    :mime_type,
    :filename,
    :platform_ref,
    metadata: %{}
  ]
end

defmodule Nex.Agent.Media.Attachment do
  @enforce_keys [:id, :channel, :kind, :mime_type, :local_path, :source, :platform_ref]
  defstruct [
    :id,
    :channel,
    :kind,
    :mime_type,
    :filename,
    :local_path,
    :size_bytes,
    :source,
    :message_id,
    :platform_ref,
    metadata: %{}
  ]
end
```

3. `ContextBuilder.build_messages/6` 的媒体输入冻结为：

```elixir
media :: [Nex.Agent.Media.Attachment.t()] | nil
```

4. `ContextBuilder` 不再接收 channel 私有 media map 作为长期 contract。

5. `Media.Attachment.local_path` 在 attachment 阶段必须存在。
   - attachment 不能以 data URL 作为真相源

6. provider-native multimodal input 是主路径。
   - image 第一版必须走 provider-native image content part
   - audio / video / file 第一版允许先 fallback text

7. phase5 的 first-path 冻结为 Feishu。
   - Telegram / Discord 只保留未来接入边界，不要求本 phase 完整实现

8. phase5 不做出站媒体发送。
   - 本地文件上传、Feishu `image_key/file_key` 出站发送属于 phase6

9. `Inbound.Envelope` 是跨模块真相源。
   - Bus 发布的 inbound payload 必须是 `%Nex.Agent.Inbound.Envelope{}`
   - `InboundWorker` 直接消费 `%Nex.Agent.Inbound.Envelope{}`
   - 不再允许“旧式 payload map + metadata 新字段”并行存在

10. `Runner` 与 `ContextBuilder` 的最小调用 contract 冻结为：

```elixir
# InboundWorker
%Envelope{text: content, attachments: attachments, channel: channel, chat_id: chat_id} = envelope

state.agent_prompt_fun.(
  agent,
  content,
  [
    channel: channel,
    chat_id: chat_id,
    media: attachments
  ]
)

# Runner
attachments = Keyword.get(opts, :media)

messages =
  ContextBuilder.build_messages(history, prompt, channel, chat_id, attachments, ...)
```

11. `ContextBuilder` 与 provider projection 的最小接口冻结为：

```elixir
defmodule Nex.Agent.Media.Projector do
  @spec project_for_model([Nex.Agent.Media.Attachment.t()] | nil, keyword()) :: [map()]
end

# image first-path target shape
%{
  "type" => "image",
  "source" => %{
    "type" => "file",
    "path" => "/abs/path/to/file"
  }
}
```

如果底层 `ReqLLM` / provider 最终只接受 URL/data URL，而不接受 file path，则 `Media.Projector` 负责在 projection 时做临时转换；`Attachment` 本身仍保持 `local_path` 为真相源。

## 执行顺序 / stage 依赖

- Stage 1: 冻结 envelope / ref / attachment contract
- Stage 2: 接入 Feishu inbound envelope + media refs
- Stage 3: 接入 Media store / hydration，先落地 image
- Stage 4: 接入 provider-native model projection
- Stage 5: 调整 InboundWorker / Runner / ContextBuilder 主链
- Stage 6: 测试、索引、handoff

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1 和 Stage 2。  
Stage 4 依赖 Stage 1 和 Stage 3。  
Stage 5 依赖 Stage 3 和 Stage 4。  
Stage 6 依赖 Stage 2、3、4、5。

## Stage 1

### 前置检查

- 先读 findings，确认 `metadata["media"]` 不再作为长期 contract。
- 确认当前 Feishu / Telegram 图片路径都还是 data URL。
- 确认本 stage 不改任何 provider、channel 的业务行为，只冻结结构和入口。

### 这一步改哪里

- 新增 `lib/nex/agent/inbound/envelope.ex`
- 新增 `lib/nex/agent/media/ref.ex`
- 新增 `lib/nex/agent/media/attachment.ex`
- 需要时新增 `lib/nex/agent/media.ex`
- 新增：
  - `test/nex/agent/media/attachment_test.exs`
  - `test/nex/agent/inbound/envelope_test.exs`

### 这一步要做

- 落地三个 struct。
- 冻结最小字段，不预留不确定大而全字段。
- 冻结 helper：
  - `Media.Attachment.image?/1`
  - `Media.Attachment.audio?/1`
  - `Media.Attachment.video?/1`
  - `Media.Attachment.file?/1`
- 明确 `platform_ref` 只是平台引用容器，不进入 prompt build。

helper 直接按下面签名落：

```elixir
@spec image?(t()) :: boolean()
@spec audio?(t()) :: boolean()
@spec video?(t()) :: boolean()
@spec file?(t()) :: boolean()
```

判定规则冻结为：

```elixir
def image?(%__MODULE__{kind: :image}), do: true
def image?(_), do: false
```

### 实施注意事项

- 这一 stage 不要开始写下载逻辑。
- 不要把 outbound 字段混进 inbound attachment。
- struct 的字段语义写在 type / moduledoc 里，减少漂移。

### 本 stage 验收

- reviewer 能直接看出入站媒体主链的统一数据边界。
- 后续 stage 不需要再发明新的中间 shape。

### 本 stage 验证

- `mix test test/nex/agent/media/attachment_test.exs`
- `mix test test/nex/agent/inbound/envelope_test.exs`

## Stage 2

### 前置检查

- Stage 1 struct 已冻结。
- 读清 `Feishu.normalize_message/3`、`normalize_inbound_content/3`、`maybe_attach_inbound_media/2`。
- 明确当前 Feishu 里 `resources` 已经是近似 `Media.Ref` 候选。

### 这一步改哪里

- 更新 `lib/nex/agent/channel/feishu.ex`
- 新增 `lib/nex/agent/channel/feishu/inbound.ex`
- 更新：
  - `test/nex/agent/channel_feishu_test.exs`

### 这一步要做

- 把 Feishu inbound normalize 主链改为先产出 `Inbound.Envelope`。
- `normalize_inbound_content/3` 不再直接把 hydrated media 写成最终 contract。
- 把现有 `resources` 迁成 `Media.Ref`：
  - image -> `%Media.Ref{kind: :image, platform_ref: %{image_key, message_id}}`
  - audio/file/media -> `%Media.Ref{kind: ..., platform_ref: %{file_key, message_id}}`
  - post image -> 同样产出 image refs
- Bus 发布主链直接切到 `%Inbound.Envelope{}`，不再发布旧式 inbound map。

Feishu image ref 直接按下面 shape 落：

```elixir
%Nex.Agent.Media.Ref{
  channel: "feishu",
  kind: :image,
  message_id: message_id,
  mime_type: nil,
  filename: nil,
  platform_ref: %{
    "image_key" => image_key,
    "message_id" => message_id
  },
  metadata: %{}
}
```

Feishu file/audio/media ref 直接按下面 shape 落：

```elixir
%Nex.Agent.Media.Ref{
  channel: "feishu",
  kind: :file | :audio | :video,
  message_id: message_id,
  mime_type: nil,
  filename: file_name,
  platform_ref: %{
    "file_key" => file_key,
    "message_id" => message_id,
    "resource_type" => "file" | "audio" | "media"
  },
  metadata: %{
    "duration" => duration
  }
}
```

`kind` 映射冻结为：

```elixir
"image" -> :image
"audio" -> :audio
"media" -> :video
"file" -> :file
"sticker" -> :file
```

Bus inbound payload 主链最小 shape 冻结为：

```elixir
%Nex.Agent.Inbound.Envelope{
  channel: "feishu",
  chat_id: reply_target,
  sender_id: sender_id,
  user_id: user_id,
  message_id: message_id,
  text: summary_text,
  message_type: :text | :image | :audio | :video | :file,
  raw: raw_payload,
  metadata: %{
    "message_type" => msg_type
  },
  media_refs: refs,
  attachments: []
}
```

### 实施注意事项

- 不保留旧 inbound payload map 兼容层。
- 先删旧路径，再用 compile/test failures 驱动 `InboundWorker`、tests、call sites 全量迁移。
- 不要在本 stage 继续做 data URL hydration。

### 本 stage 验收

- Feishu inbound 已直接发布 `Inbound.Envelope`。
- image/file/audio/media 至少都能进 `media_refs`。
- 后续 stage 可以只围绕 `Media.Ref` 做 hydration。

### 本 stage 验证

- `mix test test/nex/agent/channel_feishu_test.exs`

## Stage 3

### 前置检查

- Stage 2 已能稳定产出 `Media.Ref`。
- 确认当前没有统一 media store。
- 用户已经接受“前半段直接持久化为文件”。

### 这一步改哪里

- 新增 `lib/nex/agent/media/store.ex`
- 新增 `lib/nex/agent/media/hydrator.ex`
- 更新 `lib/nex/agent/channel/feishu.ex`
- 更新：
  - `test/nex/agent/channel_feishu_test.exs`
  - `test/nex/agent/media/store_test.exs`

### 这一步要做

- 新增统一媒体落地目录 helper。
- 第一版先实现 image hydration：
  - Feishu image ref -> 下载二进制 -> 持久化本地文件 -> `Media.Attachment`
- 对 file/audio/media ref：
  - 第一版先保留 `Media.Ref`
  - attachment 可先不 hydrate 完整内容，但必须保留扩展点，不 silent drop
- `maybe_attach_inbound_media/2` 从“data URL map”改成 attachment 列表。

`Media.Store` 第一版接口直接按下面落：

```elixir
defmodule Nex.Agent.Media.Store do
  @spec put_binary(binary(), keyword()) :: {:ok, Nex.Agent.Media.Attachment.t()} | {:error, term()}
  @spec media_dir(keyword()) :: String.t()
end
```

落地目录规则冻结为：

```text
<workspace_or_tmp>/media/inbound/YYYY-MM-DD/
```

hydrator 接口直接按下面落：

```elixir
defmodule Nex.Agent.Media.Hydrator do
  @spec hydrate_refs([Nex.Agent.Media.Ref.t()], keyword()) ::
          {[Nex.Agent.Media.Attachment.t()], [Nex.Agent.Media.Ref.t()]}
end
```

第一版 `hydrate_refs/2` 的伪代码冻结为：

```elixir
for ref <- refs do
  case ref do
    %Ref{channel: "feishu", kind: :image} ->
      download bytes via message resource api
      case Media.Store.put_binary(body, opts) do
        {:ok, attachment} -> append attachment
        {:error, reason} ->
          log warning
          keep ref in unresolved list
      end

    %Ref{} ->
      keep ref in unresolved list
  end
end
```

第一版 image attachment 直接按下面 shape 落：

```elixir
%Nex.Agent.Media.Attachment{
  id: "media_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
  channel: "feishu",
  kind: :image,
  mime_type: mime_type,
  filename: filename,
  local_path: local_path,
  size_bytes: byte_size(body),
  source: :inbound,
  message_id: message_id,
  platform_ref: %{"image_key" => image_key},
  metadata: %{}
}
```

### 实施注意事项

- 第一版不要为了快继续把图片转成 data URL。
- store 只负责落地和路径分配，不负责 provider projection。
- 下载失败或写盘失败都必须：
  - 记录 warning
  - 把 ref 留在 unresolved list
  - 继续返回 envelope，不使整条 inbound message task crash
- `Hydrator` 不允许把 store/download 异常向上冒成主链 crash。
  - 继续返回 envelope，不使整条 inbound message task crash
- `Hydrator` 不允许把 store/download 异常向上冒成主链 crash。

### 本 stage 验收

- Feishu image inbound 会落地成本地文件。
- inbound metadata 可以拿到 attachment，而不是 data URL。
- store / hydrator 已经独立于 Feishu channel 主体。

### 本 stage 验证

- `mix test test/nex/agent/channel_feishu_test.exs`
- `mix test test/nex/agent/media/store_test.exs`

## Stage 4

### 前置检查

- Stage 3 已产出本地 image attachment。
- 读清 `ContextBuilder.build_user_content/2` 和 `ReqLLM.to_content_part/1`。
- 明确当前 provider-native image input 已经存在，但入口 shape 太弱。

### 这一步改哪里

- 新增 `lib/nex/agent/media/projector.ex`
- 更新 `lib/nex/agent/context_builder.ex`
- 更新 `lib/nex/agent/llm/req_llm.ex`
- 更新：
  - `test/nex/agent/context_builder_test.exs`
  - `test/nex/agent/llm/req_llm_test.exs`

### 这一步要做

- 新增 provider projection helper：
  - `project_for_model/2`
  - 第一版至少支持 image attachment
- `ContextBuilder.build_user_content/2` 改为消费 `[Media.Attachment]`。
- `ReqLLM` 保持现有 image content part 能力，但输入不再来自平台私有 map。
- 第一版对非 image attachment 固定行为：
  - 生成确定性 fallback text
  - 不 silent drop

`Media.Projector` 第一版接口和返回值直接按下面落：

```elixir
defmodule Nex.Agent.Media.Projector do
  @spec project_for_model([Nex.Agent.Media.Attachment.t()] | nil, keyword()) :: [map()]
end
```

第一版 image projection 伪代码冻结为：

```elixir
def project_for_model(nil, _opts), do: []

def project_for_model(attachments, opts) do
  Enum.flat_map(attachments, fn
    %Attachment{kind: :image, local_path: path, mime_type: mime} ->
      [
        %{
          "type" => "image",
          "source" => %{
            "type" => "file",
            "path" => path,
            "media_type" => mime
          }
        }
      ]

    %Attachment{kind: kind, filename: filename} ->
      [
        %{
          "type" => "text",
          "text" => "[User sent #{kind}: #{filename || "attachment"}]"
        }
      ]
  end)
end
```

`ContextBuilder.build_user_content/2` 目标伪代码冻结为：

```elixir
defp build_user_content(text, nil), do: text

defp build_user_content(text, attachments) when is_list(attachments) and attachments != [] do
  projected = Nex.Agent.Media.Projector.project_for_model(attachments, [])
  projected ++ [%{"type" => "text", "text" => text}]
end
```

`ReqLLM.to_content_part/1` 第一版至少补下面 shape：

```elixir
%{"type" => "image", "source" => %{"type" => "file", "path" => path, "media_type" => mime}}
```

如果 `ReqLLM.ContentPart` 当前不支持 file-based image input，则在这里先做临时 file->data_url 转换，但转换点只能在 `ReqLLM` / provider projection，不能回写 attachment。

### 实施注意事项

- provider projection 只做格式投影，不做文件下载。
- 不要把 OpenAI/Anthropic 私有格式写进 `ContextBuilder`。
- image first-path 完成后，再给 audio/video/file 留接口，不在本 stage 硬补。

### 本 stage 验收

- attachment 已进入 provider-native multimodal input 主链。
- `ContextBuilder` 不再知道 `url/media_type` 是从哪个 channel 来的。
- image 入站端到端闭环完成。

### 本 stage 验证

- `mix test test/nex/agent/context_builder_test.exs`
- `mix test test/nex/agent/llm/req_llm_test.exs`

## Stage 5

### 前置检查

- Stage 3 / 4 已完成 image attachment + provider projection。
- 读清 `InboundWorker.dispatch_async/5`、`extract_media/1`、`Runner.run/3`。
- 确认 Stage 2 已经把 Bus inbound payload 主链切成 `%Inbound.Envelope{}`。

### 这一步改哪里

- 更新 `lib/nex/agent/inbound_worker.ex`
- 更新 `lib/nex/agent/runner.ex`
- 需要时更新：
  - `lib/nex/agent.ex`
- 更新：
  - `test/nex/agent/inbound_worker_test.exs`

### 这一步要做

- `InboundWorker` 直接消费 `%Nex.Agent.Inbound.Envelope{}`。
- 删除旧 `extract_media/1` 长期路径。
- `Runner` 的 `opts[:media]` 语义冻结为 attachments。
- 清掉现有硬编码的“只认 image media map”调用链。

`InboundWorker` 主链 helper 伪代码冻结为：

```elixir
defp handle_inbound(%Nex.Agent.Inbound.Envelope{} = envelope, state) do
  content = envelope.text
  attachments = envelope.attachments
  dispatch_async(state, key, session_key, workspace, content, envelope, attachments)
end
```

`dispatch_async/7` 的调用意图冻结为：

```elixir
result =
  state.agent_prompt_fun.(
    agent,
    content,
    [
      channel: channel,
      chat_id: chat_id,
      media: attachments
    ]
  )
```

### 实施注意事项

- 不保留 `metadata["media"]` fallback。
- 不要在本 stage 接 Telegram / Discord 新实现。
- compile errors 应驱动所有 `media` 旧入口一处处迁掉。

### 本 stage 验收

- 主链已从平台私有 `metadata["media"]` 转移到 attachment contract。
- Feishu image inbound 端到端稳定。
- phase5 结束后，后续接 Telegram / Discord 不需要再改 `ContextBuilder` / `ReqLLM` 主链。

### 本 stage 验证

- `mix test test/nex/agent/inbound_worker_test.exs`
- `mix test test/nex/agent/channel_feishu_test.exs`
- `mix test test/nex/agent/context_builder_test.exs`

## Stage 6

### 前置检查

- Stage 1-5 已全部落地。
- 确认 `CURRENT.md` 已经把 phase5 作为 active mainline；若本轮落地后状态变化，再做同步更新。

### 这一步改哪里

- 更新 `docs/dev/task-plan/index.md`
- 更新 `docs/dev/progress/CURRENT.md`
- 更新 `docs/dev/progress/2026-04-16.md`

### 这一步要做

- 把 phase5 加到 index 和 CURRENT。
- 在 CURRENT 中明确：
  - phase4 已关闭为文本 IR foundation
  - phase4a 已 superseded
  - phase5 是新的 active mainline
- 记录 reviewer 最小命令：
  - Feishu image inbound -> attachment hydration
  - ContextBuilder attachment projection
  - InboundWorker main path

### 实施注意事项

- 不把 CURRENT 写成 changelog。
- 只保留后续 executor 继续 phase5 所需的最小上下文。

### 本 stage 验收

- phase5 已成为当前主线。
- reviewer 知道 phase4/4a 不再继续执行。

### 本 stage 验证

- 人工检查：
  - `docs/dev/task-plan/index.md`
  - `docs/dev/progress/CURRENT.md`

## Review Fail 条件

- 继续把 channel 私有 media map 暴露给 `ContextBuilder`。
- 在 phase5 主链里保留 `metadata["media"]` fallback 或兼容 shim。
- `Inbound.Envelope` 仍然只是 channel 内部临时对象，而不是 Bus / InboundWorker 真正消费的边界。
- attachment 仍然以 data URL 作为真相源。
- phase5 中混入 Feishu outbound send/upload 逻辑。
- provider-native multimodal input 被重新改回工具摘要主路径。
- phase5 文档没有冻结 struct 和直接可改代码路径。
