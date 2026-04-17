# Phase 4A Feishu Native Capabilities And Media

> Status: Superseded before implementation.
> Do not execute this plan.
> Replaced by `phase5-im-inbound-architecture-and-media-projection.md` and `phase6-feishu-outbound-official-format-and-media-send.md`.

## 当前状态

- phase4 已把 Feishu 从“弱 markdown 字符串直发”推进到 `IMIR -> Feishu payload` 主链，但当前实现仍然是文本优先版本。
- 当前仓库已经具备以下零散能力，但还没有收敛成完整可执行主线：
  - `message` tool 支持 Feishu 显式 `msg_type + content_json`
  - `message` tool 支持 `local_image_path`
  - `Nex.Agent.Channel.Feishu` 已支持 `image/file/audio/media/sticker/share_chat/share_user/system` 等显式消息类型透传
  - inbound 已能识别 `image`、部分 `post` 资源和若干 share/system 类消息
- 当前缺口集中在三类：
  - 没有完整的媒体资产上传主链。图片之外，视频 / 音频 / 文件仍缺少“本地文件 -> upload -> send”统一能力
  - Feishu card 仍主要停留在旧结构和 `lark_md` 文本块，未切到官方 JSON 2.0 主路径
  - phase4 的文本 IR 设计没有把多媒体纳入冻结边界，导致“原生消息附件”“卡片内媒体组件”“文本 IR 里的媒体引用”三条路径混在一起

## 完成后必须达到的结果

- 仓库内 Feishu 的用户可见输出被明确拆成三条主路径，并各自可验证：
  - 显式原生消息类型发送
  - JSON 2.0 card 渲染 / patch / streaming
  - 媒体资产上传与 inbound 媒体回填
- Feishu 原生消息类型至少覆盖官方主路径里与当前 agent 相关的用户可见类型：
  - `text`
  - `post`
  - `interactive`
  - `image`
  - `file`
  - `audio`
  - `media`
  - `sticker`
  - `share_chat`
  - `share_user`
  - `system`
- 本地文件发送不再只支持图片：
  - 本地图片可上传并发送 `image`
  - 本地普通文件可上传并发送 `file`
  - 本地音频可上传并发送 `audio`
  - 本地视频可上传并发送 `media`
- Feishu card 主路径切到 JSON 2.0：
  - `schema: "2.0"`
  - `config.update_multi: true`
  - `config.streaming_mode` 可由 channel runtime 控制
  - 表格、图片、富文本 markdown 至少能走官方 JSON 2.0 可验证结构，而不是继续全部降级成旧式 `div -> lark_md`
- inbound 侧对图片 / 文件 / 音频 / 视频有统一归一化结果，后续 `ContextBuilder.build_messages/6` 可稳定把可消费媒体交给模型。
- phase4a 结束后，Feishu “文本能力”和“媒体能力”不再彼此绕路或隐式耦合，后续 executor 能单独推进任一条链路。

## 开工前必须先看的代码路径

- `docs/dev/task-plan/phase4-im-text-ir-and-renderers.md`
- `docs/dev/progress/CURRENT.md`
- `lib/nex/agent/channel/feishu.ex`
- `lib/nex/agent/stream/feishu_session.ex`
- `lib/nex/agent/im_ir/parser.ex`
- `lib/nex/agent/im_ir/block.ex`
- `lib/nex/agent/im_ir/render_result.ex`
- `lib/nex/agent/im_ir/renderers/feishu.ex`
- `lib/nex/agent/im_ir/text.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/tool/message.ex`
- `lib/nex/agent/inbound_worker.ex`
- `test/nex/agent/channel_feishu_test.exs`
- `test/nex/agent/im_ir/parser_test.exs`
- `test/nex/agent/im_ir/feishu_renderer_test.exs`
- `test/nex/agent/stream/new_message_boundary_test.exs`
- `test/nex/agent/context_builder_test.exs`

飞书官方对照文档开工前至少先看这些：

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

本 phase4a 固定以下边界。

1. 对模型的正文接口继续冻结为 `String.t()`。
   - 不新增“正文直接传卡片 JSON”
   - 不新增“正文直接传媒体二进制”
   - `final_content` canonical 仍是模型原始文本 IR

2. Feishu 输出主链拆成三条，职责固定：
   - 文本 IR -> JSON 2.0 card renderer
   - 显式 `msg_type + content_json` -> 原生消息发送
   - 本地文件 -> 上传资产 -> 原生消息发送 / card 组件引用

3. renderer 不负责上传资产。
   - renderer 只消费已有 `image_key` / `file_key` / 纯文本
   - 上传逻辑只允许放在 Feishu channel / asset helper / message tool 适配层

4. `message` tool 的 Feishu 文件发送 contract 冻结为：
   - 保留 `content`
   - 保留 `msg_type`
   - 保留 `content_json`
   - 保留 `local_image_path`
   - 新增 `local_file_path`
   - 当 `local_file_path` 存在时，`msg_type` 必须显式为：
     - `file`
     - `audio`
     - `media`
     - `sticker`
   - 不新增 `local_audio_path` / `local_video_path` / `local_sticker_path` 这类平铺字段

5. Feishu card 主路径从本 phase 起冻结为 JSON 2.0。
   - `schema` 必须为 `"2.0"`
   - `config.update_multi` 必须显式为 `true`
   - `config.streaming_mode` 与 channel runtime `streaming` 对齐
   - `send_card/3` 与 `update_card/2` 不再继续以旧结构作为主路径

6. Feishu streaming card 的基础 config 最小 shape 冻结为：

```elixir
%{
  "schema" => "2.0",
  "config" => %{
    "update_multi" => true,
    "streaming_mode" => boolean(),
    "summary" => %{"content" => String.t()}
  },
  "header" => map() | nil,
  "body" => %{"elements" => [map()]}
}
```

7. inbound 侧统一媒体归一化 shape 冻结为：

```elixir
%{
  "type" => "image" | "file" | "audio" | "media",
  "mime_type" => String.t() | nil,
  "url" => String.t() | nil,
  "image_key" => String.t() | nil,
  "file_key" => String.t() | nil,
  "file_name" => String.t() | nil,
  "message_id" => String.t() | nil
}
```

说明：

- `url` 允许为 data URL，也允许后续改成受控下载 URL，但同一版本内必须固定一种可验证行为
- `sticker` 若官方返回结构最终只能映射为 `file` 或纯占位文本，必须在测试里固定，不允许静默漂移

8. phase4a 的 Feishu card 目标范围冻结为“用户可见展示能力”，不是“全量交互生态”。
   - 必做：markdown、table、image、divider、header、summary、streaming config
   - 可选：人员、人员列表、chart、多图混排
   - 不要求在本 phase 同时完成所有交互型组件、表单容器、回调生态和模板卡片管理

9. Feishu IR 中的媒体引用边界冻结为：
   - 纯文本 IR 仍然是主输入
   - 当正文中出现已知可验证的媒体引用语法时，renderer 可以将其转成 card 组件或 markdown 2.0 支持的媒体语法
   - 但不得在正文里引入“上传本地文件”的隐式语义

10. 显式原生消息类型与 card renderer 不互相回退覆盖。
    - 调用方显式给了 `msg_type + content_json`，就走原生消息发送
    - 只有默认正文路径才走 card renderer
    - 不允许把显式 `audio/media/file` 再偷偷转成 card 文本解释

11. phase4a 不为了“全特性”而加入新的兼容 shim。
    - 旧 card 结构可以短期保留在测试迁移窗口内
    - 但主路径必须切到 JSON 2.0，再用 compile/test failures 驱动全链更新

12. 本 phase 的明确非目标：
    - 重新设计跨平台统一重型富文本 AST
    - 在正文主链中加入平台原生 JSON 逃生口
    - 完整落地飞书所有交互组件和 callback 业务
    - 让非 Feishu channel 同日获得相同媒体能力

## 执行顺序 / stage 依赖

- Stage 1: 冻结 Feishu 能力矩阵与消息/媒体 contract
- Stage 2: 接入本地文件上传与原生媒体消息发送主链
- Stage 3: 把 Feishu card 主路径切到 JSON 2.0
- Stage 4: 扩展 Feishu IR / renderer 覆盖 markdown、table、image、audio 等展示能力
- Stage 5: 扩展 inbound 媒体归一化与 hydration
- Stage 6: 调整 prompt、工具说明、文档索引与人工 smoke

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1。  
Stage 4 依赖 Stage 3。  
Stage 5 依赖 Stage 2 和 Stage 3。  
Stage 6 依赖 Stage 2、3、4、5。

## Stage 1

### 前置检查

- 读清当前 `message` tool、`Feishu.do_send/2`、`build_outbound_content/3`、`upload_local_image/2`。
- 读清 phase4 已冻结的 `final_content`、`<newmsg/>`、`streaming` 边界，避免在本 stage 重新定义。
- 对照官方文档确认以下事实后再动代码：
  - 图片走 `image_key`
  - 文件 / 音频 / 视频走上传文件接口，发送时使用 `file_key`
  - 卡片更新走 PATCH
  - JSON 2.0 card 仅支持 `update_multi: true`

### 这一步改哪里

- 新增 `docs/dev/findings/2026-04-16-feishu-native-capabilities-and-media.md`（如需要记录官方能力矩阵）
- 新增 `docs/dev/task-plan/phase4a-feishu-native-capabilities-and-media.md`
- 更新 `lib/nex/agent/tool/message.ex`
- 更新 `lib/nex/agent/context_builder.ex`
- 新增或更新：
  - `test/nex/agent/context_builder_test.exs`
  - `test/nex/agent/channel_feishu_test.exs`

### 这一步要做

- 冻结 Feishu 能力矩阵：
  - 默认正文 -> JSON 2.0 card
  - 显式 `msg_type + content_json` -> 原生消息
  - 本地图片 / 文件 -> 先上传再发送
- 冻结 `message` tool 的 `local_file_path` contract。
- 冻结 inbound `metadata["media"]` 的统一 shape。
- 在 prompt / tool 描述中明确：
  - 什么时候应该用 `content`
  - 什么时候应该用 `msg_type + content_json`
  - 什么时候应该用 `local_image_path` / `local_file_path`
  - 没有 `image_key` / `file_key` 时不得猜测

### 实施注意事项

- 本 stage 先冻边界，不在这里把所有上传逻辑一次写完。
- 不要把“卡片内图片组件”和“原生 image 消息”写成同一条 contract。
- findings 只写官方能力矩阵和关键限制，不写成长散文。

### 本 stage 验收

- reviewer 能直接看到 Feishu 三条发送主链已分开定义。
- `message` tool 对本地文件发送的 contract 已固定。
- 后续 stage 不需要再重新解释 `image_key` / `file_key` / card JSON 2.0 的角色。

### 本 stage 验证

- `mix test test/nex/agent/context_builder_test.exs`
- `mix test test/nex/agent/channel_feishu_test.exs`

## Stage 2

### 前置检查

- Stage 1 已冻结 `local_file_path` contract。
- 确认当前仓库只有 `upload_local_image/2`，没有统一文件上传 helper。
- 明确官方文件上传接口会返回 `file_key`，后续由 `msg_type=file|audio|media|sticker` 消费。

### 这一步改哪里

- 更新 `lib/nex/agent/channel/feishu.ex`
- 更新 `lib/nex/agent/tool/message.ex`
- 需要时新增：
  - `lib/nex/agent/channel/feishu/asset.ex`
- 更新：
  - `test/nex/agent/channel_feishu_test.exs`
  - `test/nex/agent/tool_message_test.exs`

### 这一步要做

- 抽出统一资产上传主链：
  - 上传图片 -> `image_key`
  - 上传文件 -> `file_key`
- 为 `message` tool 接入：
  - `local_file_path + msg_type=file`
  - `local_file_path + msg_type=audio`
  - `local_file_path + msg_type=media`
  - `local_file_path + msg_type=sticker`
- 保持以下行为可预测：
  - `content + local_image_path`：先文字，后图片
  - `content + local_file_path`：仅当 contract 明确允许时发送两条；否则直接报错，不做隐式组合
  - `content_json` 已带 `file_key` / `image_key` 时不得重复上传

### 实施注意事项

- 文件类型判断不要靠扩展名猜测 `msg_type`。
- `msg_type=media` 的视频发送必须要求调用方显式传入，不要靠 MIME 自动猜成视频。
- 若 sticker 的 payload shape 与 `file_key` 不一致，必须按官方结构单独校验；没确认前不要复用 `file_key` 假设。

### 本 stage 验收

- Feishu 不再只有 `local_image_path`。
- executor 可以从本地路径稳定发送图片、文件、音频、视频。
- 显式 `msg_type + content_json` 和本地上传发送共存且互不打架。

### 本 stage 验证

- `mix test test/nex/agent/channel_feishu_test.exs`
- `mix test test/nex/agent/tool_message_test.exs`

## Stage 3

### 前置检查

- Stage 1 已冻结 JSON 2.0 card 最小 shape。
- 读清当前 `Feishu.render_card/1`、`Feishu.send_card/3`、`Feishu.update_card/2`、`FeishuSession`。
- 确认当前 patch 路径还没有显式 `schema: "2.0"` / `update_multi: true` / `streaming_mode`。

### 这一步改哪里

- 更新 `lib/nex/agent/im_ir/renderers/feishu.ex`
- 更新 `lib/nex/agent/channel/feishu.ex`
- 更新 `lib/nex/agent/stream/feishu_session.ex`
- 更新：
  - `test/nex/agent/im_ir/feishu_renderer_test.exs`
  - `test/nex/agent/channel_feishu_test.exs`
  - `test/nex/agent/stream/new_message_boundary_test.exs`

### 这一步要做

- 把 `render_card/1` 主输出切到 JSON 2.0：
  - `schema`
  - `config.update_multi`
  - `config.streaming_mode`
  - `config.summary`
  - `header`
  - `body.elements`
- `FeishuSession.open_session/4` 创建的占位卡片也切到 JSON 2.0。
- `FeishuSession` 在 `streaming?` 下通过 JSON 2.0 card patch 更新正文。
- 收敛 send / patch 共用的 card builder，不允许再各自拼不同结构。

### 实施注意事项

- 本 stage 先做 card 骨架，不要求一次把所有组件映射做完。
- `summary` 需要与 streaming 状态同步，但不得覆盖 canonical `final_content`。
- 若客户端版本对 JSON 2.0 有兜底提示，这是客户端能力限制，不应把主路径退回 1.0。

### 本 stage 验收

- Feishu card 主路径已明确是 JSON 2.0。
- send_card / update_card / session patch 共用同一套 card shape。
- streaming config 已从 runtime 正常传到 card config。

### 本 stage 验证

- `mix test test/nex/agent/im_ir/feishu_renderer_test.exs`
- `mix test test/nex/agent/channel_feishu_test.exs`
- `mix test test/nex/agent/stream/new_message_boundary_test.exs`

## Stage 4

### 前置检查

- Stage 3 的 JSON 2.0 card 骨架已可稳定发送。
- 读清官方 JSON 2.0 markdown / table / image / audio 能力文档。
- 确认当前 renderer 仍主要把 block 降级成 `lark_md` 文本块。

### 这一步改哪里

- 更新 `lib/nex/agent/im_ir/block.ex`
- 更新 `lib/nex/agent/im_ir/parser.ex`
- 更新 `lib/nex/agent/im_ir/render_result.ex`
- 更新 `lib/nex/agent/im_ir/profiles/feishu.ex`
- 更新 `lib/nex/agent/im_ir/renderers/feishu.ex`
- 新增或更新：
  - `test/nex/agent/im_ir/parser_test.exs`
  - `test/nex/agent/im_ir/feishu_renderer_test.exs`

### 这一步要做

- 在不破坏字符串 contract 的前提下，把 Feishu renderer 扩到官方 JSON 2.0 可验证展示能力：
  - heading -> markdown 2.0 标题
  - list -> markdown 2.0 列表
  - quote -> markdown 2.0 引用
  - code_block -> markdown 2.0 代码块
  - table -> 优先 `table` 组件，不再默认降级为纯 markdown
  - image 引用 -> `img` 组件或 markdown image 语法
  - audio 引用 -> markdown `<audio ...></audio>` 或显式 audio 组件
- 冻结 Feishu IR 的媒体引用第一版语法：
  - 已有 `image_key` 的图片引用
  - 已有 `file_key` 的音频引用
  - 未持有 key 时只允许保留文本，不允许隐式上传
- 对仍然无法稳定渲染的能力给出固定降级：
  - 比如 video 内嵌 card 若本轮不做原生组件，则固定降级为链接 / 原生 `media` 消息，不要 silent drift

### 实施注意事项

- parser 新增媒体 block 时，只处理“可确定识别且不依赖网络状态”的语法。
- 不要把任意 URL 图片、任意本地路径写进 renderer 主链。
- table 组件和 markdown table 只能保留一个主路径；若二者并存，必须写清优先级和降级规则。

### 本 stage 验收

- Feishu 不再把 table 一律降级成纯文本 markdown。
- 图片 / 音频至少有一条稳定的 card 内展示主路径。
- renderer 的多媒体支持是“已有 key 的 deterministic render”，不是“边渲染边上传”的隐式副作用。

### 本 stage 验证

- `mix test test/nex/agent/im_ir/parser_test.exs`
- `mix test test/nex/agent/im_ir/feishu_renderer_test.exs`

## Stage 5

### 前置检查

- Stage 2 已能发送本地图片 / 文件 / 音频 / 视频。
- 当前 inbound hydration 只真正下载 / 回填图片。
- 读清 `normalize_inbound_content/3` 与 `maybe_attach_inbound_media/2`。

### 这一步改哪里

- 更新 `lib/nex/agent/channel/feishu.ex`
- 更新 `lib/nex/agent/inbound_worker.ex`
- 更新 `lib/nex/agent/context_builder.ex`
- 更新：
  - `test/nex/agent/channel_feishu_test.exs`
  - `test/nex/agent/context_builder_test.exs`

### 这一步要做

- 扩展 inbound 归一化：
  - `image`
  - `file`
  - `audio`
  - `media`
  - `sticker`（若能稳定映射）
- 为可下载资源补 hydration：
  - 图片至少支持 data URL 回填
  - 文件 / 音频 / 视频若官方允许资源下载，则按统一 shape 回填
  - 若某类资源当前拿不到二进制，则至少保留 `file_key` / `file_name` / `mime_type`
- 让 `ContextBuilder.build_messages/6` 能稳定把这些媒体透给模型，而不是只偏向图片。

### 实施注意事项

- 不要为了补全 inbound 而假设所有资源都可匿名下载。
- 下载失败必须保留可用 metadata，不要把整个 inbound media 丢掉。
- media hydration 的失败日志必须可诊断，但不能污染主链。

### 本 stage 验收

- inbound `metadata["media"]` 不再只有图片场景。
- 模型能看到 Feishu 发来的图片 / 文件 / 音频 / 视频的统一媒体描述。
- 后续 executor 能在不改 Feishu channel 主流程的前提下继续扩媒体 hydration。

### 本 stage 验证

- `mix test test/nex/agent/channel_feishu_test.exs`
- `mix test test/nex/agent/context_builder_test.exs`

## Stage 6

### 前置检查

- Stage 2、3、4、5 已全部落地。
- 当前 live Feishu 凭证可用于人工 smoke。
- 读清 `CURRENT.md` 中现有 phase4 主线描述，避免把 handoff 写成 changelog。

### 这一步改哪里

- 更新 `docs/dev/task-plan/index.md`
- 更新 `docs/dev/progress/CURRENT.md`
- 更新当日 progress log
- 需要时更新 findings 索引

### 这一步要做

- 把 phase4a 加入 task plan index 和 current pointer。
- 在 `CURRENT.md` 里明确 phase4a 是 phase4 的 Feishu native follow-up，而不是另起架构方向。
- 记录 reviewer 最小 smoke matrix：
  - Feishu `single` 文本 card
  - Feishu `streaming` JSON 2.0 card
  - table
  - image component
  - audio embed
  - native `image`
  - native `file`
  - native `audio`
  - native `media`
  - inbound image/file/audio/media normalization

### 实施注意事项

- 不要把 `CURRENT.md` 写成文件清单。
- 只记录后续执行者继续推进 phase4a 所需的最小上下文。

### 本 stage 验收

- phase4a 已成为可执行、可 review、可 handoff 的正式计划。
- reviewer 能直接按命令和 smoke matrix 验证媒体能力。

### 本 stage 验证

- 人工检查：
  - `docs/dev/task-plan/index.md`
  - `docs/dev/progress/CURRENT.md`

## Review Fail 条件

- 继续把 Feishu card 主路径停留在旧结构，而不是 JSON 2.0。
- 让 renderer 隐式上传本地文件，破坏“渲染无副作用”边界。
- 让 `local_file_path` 不要求显式 `msg_type`，靠扩展名或 MIME 猜消息类型。
- 把 `image/file/audio/media` 原生消息重新塞回“纯文本 markdown”主链。
- inbound 继续只把图片当媒体，其它 `file/audio/media` 只留占位文本。
- 没有把 `update_multi: true` 和 `streaming_mode` 作为 Feishu card 主路径固定下来。
- phase4a 文档只写“支持更多特性”，没有 stage、改哪里、验收和验证。
