# Phase 4 IM Text IR And Renderer Pipeline

> Status: Closed as text-IR foundation.
> Follow-up inbound/media architecture moved to `phase5-im-inbound-architecture-and-media-projection.md`.
> Feishu official outbound format and media send moved to `phase6-feishu-outbound-official-format-and-media-send.md`.

## 当前状态

- phase3 / phase3a 已经把统一 streaming 主链、assembler、transport session、Feishu edit-message 主路径接起来了。
- 当前用户可见正文主链仍然以普通字符串为核心，平台适配主要靠 channel 私有 formatter。
- Feishu 已经暴露出真实问题：代码块、表格、分段消息、平台特有富文本能力不能靠“通用 markdown 文本 + 少量正则”长期维持。
- 用户已经明确冻结本 phase 的方向：
  - 对模型暴露的接口保持 `String.t()`
  - 不引入 feature flag 风格的 converter 外部接口
  - 每个 IM 平台允许有自己的纯文本 IR
  - IR 尽量接近 markdown，但语法边界由该平台 parser 决定
  - `<newmsg/>` 是平台 IR 里的显式新消息标记
  - 不预留平台原生 JSON 逃生口；优先把 IR 和转换器本身做简单
- 用户也已经明确冻结本 phase 的交付模式：
  - `single`
  - `streaming`
  - `<newmsg/>` 不是模式，而是 IR 语法；它在 `single` 和 `streaming` 下都允许出现

## 完成后必须达到的结果

- `nex-agent` 新增“平台文本 IR -> 平台 payload”执行主链，而不是继续把所有平台正文都当普通 markdown 字符串直接发送。
- 对模型的正文接口保持为字符串；平台差异通过不同 parser / renderer pipeline 解决，不通过外部 feature flag 组合调用。
- 每个 channel 都可以配置是否 `streaming`。
- `single` 与 `streaming` 都继续走 session；差异在于正文是否增量 flush，不在于是否建立 session。
- `<newmsg/>` 在平台支持时能切出多条用户可见消息；在平台不支持或受限时，由该平台 renderer / session 自行降级处理。
- Feishu 先作为第一条完整落地主路径：
  - 平台 IR parser 可增量解析
  - renderer 可将文本 IR 转成 Feishu 可发送/可 patch 的 payload
  - 代码块与表格不再依赖当前“弱 markdown 转卡片”路径硬扛
- phase 结束时仓库仍保留现有 `%Nex.Agent.Stream.Event{}` / `%Nex.Agent.Turn.Stream.Result{}` 外部 streaming contract，不回退成一次性整段发送。

## 开工前必须先看的代码路径

- `docs/dev/task-plan/phase3-streaming-delivery-contract.md`
- `docs/dev/task-plan/phase3a-streaming-architecture-convergence.md`
- `lib/nex/agent/config.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/stream/assembler.ex`
- `lib/nex/agent/stream/transport.ex`
- `lib/nex/agent/stream/feishu_session.ex`
- `lib/nex/agent/stream/multi_message_session.ex`
- `lib/nex/agent/channel/feishu.ex`
- `lib/nex/agent/channel/telegram.ex`
- `lib/nex/agent/channel/discord.ex`
- `test/nex/agent/channel_feishu_test.exs`
- `test/nex/agent/inbound_worker_test.exs`
- `test/nex/agent/runner_stream_test.exs`

外部参考与对照实现先看：

- `~/Desktop/hermes-agent/gateway/stream_consumer.py`
- `~/Desktop/hermes-agent/gateway/platforms/feishu.py`
- `~/Desktop/hermes-agent/gateway/platforms/slack.py`
- `~/Desktop/hermes-agent/gateway/platforms/telegram.py`

## 固定边界 / 已冻结的数据结构与 contract

本 phase4 固定以下边界。

1. 对模型的正文输出接口继续冻结为 `String.t()`。
   - 不新增“富文本 AST 入参”
   - 不新增“平台 payload 入参”
   - 不新增“converter feature flags 入参”
2. 平台 IR 允许不同。
   - 每个平台都可以有自己的文本语法
   - 默认目标是尽量接近标准 markdown，减少模型负担
   - 语法边界以该平台 parser 定义为准，不要求平台之间完全同构
3. converter / parser 的对外输入冻结为字符串或字符串增量。
   - 允许内部实现使用 parser combinator、增量状态机、block parser
   - 但这些内部结构不得泄漏成对外接口参数
4. `<newmsg/>` 冻结为平台 IR 里的显式新消息标记。
   - 只在平台文本 IR 正文里生效
   - 在 fenced code block 内不得触发消息切分
   - renderer 不得把 `<newmsg/>` 原样展示给用户
   - 平台可以自行决定是“真切一条新消息”还是“降级处理”
5. 本 phase 的交付模式冻结为：
   - `single`
   - `streaming`
6. `single` 与 `streaming` 都需要 session。
   - `single`: 先点赞 / 先发占位态 / 等完整响应 / 再一次性输出最终结果
   - `streaming`: 先点赞 / 先发占位态 / 正文增量 flush 给前端
   - 两者差异在 flush policy，不在 session existence
7. `streaming` 是 channel runtime config，不是 converter 外部 feature flag。
   - 调用链先选定某个平台的 parser / renderer pipeline
   - 再把字符串输入交给该 pipeline
8. `<newmsg/>` 不是 message mode，不单独占一个 runtime config 字段。
   - 它是平台 IR 语法的一部分
   - 在 `single` 和 `streaming` 下都允许出现
9. `%Nex.Agent.Turn.Stream.Result.final_content` 的 canonical 内容冻结为模型原始正文。
   - 保留 `<newmsg/>`
   - 保留平台文本 IR 原文
   - 只移除 transport-only 占位、cursor、thinking/progress 文本
   - history / memory / audit 使用 canonical `final_content`
   - 用户可见文本由平台 renderer 决定，不反向覆盖 canonical `final_content`
10. `Nex.Agent.Interface.IMIR.RenderResult` 是内部 handoff shape，不是对模型或工具暴露的新接口。最小 shape 冻结为：

```elixir
%Nex.Agent.Interface.IMIR.RenderResult{
  payload: term(),
  text: String.t(),
  complete?: boolean(),
  new_message?: boolean(),
  canonical_text: String.t(),
  warnings: [term()]
}
```

字段语义冻结：

- `payload`: 平台 renderer 给 channel/session 的平台内部 payload 或 payload fragment。
- `text`: 平台降级或纯文本发送需要的用户可见文本。
- `complete?`: 当前块是否已经闭合并可安全提交给 renderer。
- `new_message?`: 当前块是否来自 `<newmsg/>` 边界；平台可真切消息或降级。
- `canonical_text`: 进入 `final_content` 的原始 IR 文本片段。
- `warnings`: renderer 的确定性降级信息；不得用于主路径控制。

11. 本 phase 不引入“平台原生 JSON 逃生口”作为新的正文主链 contract。
   - 主线目标是先把文本 IR 和 renderer pipeline 跑通
12. 本 phase 不做“全平台共享重型公共富文本 IR / AST”。
    - 若内部需要 parser 输出结构，只允许作为实现细节存在
    - 不得把它提升成新的跨平台外部 contract
13. 第一条完整落地主路径冻结为 Feishu。
    - Telegram / Discord / Slack 的平台 IR 可以先只补配置和骨架
    - 不要求本 phase 同时把全部平台 renderer 做完
14. system prompt 必须明确告诉模型：
    - 当前 channel 使用哪套平台文本 IR
    - 当前 channel 是否 `streaming`
    - 当前平台不该输出哪些块
    - `<newmsg/>` 的使用规则
15. 平台不支持的块优先通过 system prompt 约束模型不要输出。
    - 不把复杂纠错/智能修复作为本 phase converter 的 blocking 范围
    - renderer 只做必要的、确定性的格式转换与降级

## 执行顺序 / stage 依赖

- Stage 1: 接入 session / config / flush policy contract
- Stage 2: 冻结 `<newmsg/>` 与平台文本 IR parser contract
- Stage 3: 接入 Feishu 文本 IR parser 与 renderer
- Stage 4: 验证 `<newmsg/>` 在 `single` / `streaming` 下的平台行为
- Stage 5: 调整 system prompt 与平台约束提示
- Stage 6: 回归验证、文档索引与 reviewer 检查点

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1 和 Stage 2。  
Stage 4 依赖 Stage 1 和 Stage 3。  
Stage 5 依赖 Stage 1。  
Stage 6 依赖 Stage 3、Stage 4、Stage 5。

## Stage 1

### 前置检查

- 先确认 phase3 / phase3a 外部 streaming contract 已冻结，不在本 stage 重开。
- 确认用户已经明确接受：
  - 接口是字符串
  - 平台 IR 可不同
  - `<newmsg/>` 是平台 IR 语法
  - `single` 与 `streaming` 都需要 session

### 这一步改哪里

- 新增 `docs/dev/findings/2026-04-16-im-text-ir-and-renderer-pipeline.md`
- 更新 `lib/nex/agent/config.ex`
- 更新 `lib/nex/agent/runtime/snapshot.ex`
- 更新 `lib/nex/agent/inbound_worker.ex`
- 更新 `lib/nex/agent/stream/transport.ex`
- 需要时更新：
  - `lib/nex/agent/stream/feishu_session.ex`
  - `lib/nex/agent/stream/multi_message_session.ex`
- 新增或更新：
  - `test/nex/agent/inbound_worker_test.exs`
  - `test/nex/agent/stream/streaming_config_test.exs`

### 这一步要做

- 冻结 phase4 设计结论，重点只写执行所需冻结项：
  - 平台文本 IR 是字符串 contract
  - 平台 IR 允许不同
  - `<newmsg/>` 语义
  - `single` / `streaming` 语义
- 增加 per-channel `streaming` config。
- 增加 runtime snapshot 可读字段，让 transport 和 prompt 共用同一份 `streaming` 信息。
- 前移冻结 session 选择逻辑：
  - `single` 与 `streaming` 都创建 session
  - 但 `single` session 不得把 assistant 正文增量 flush 给用户
  - `streaming` session 才允许正文增量 flush
- 冻结 finalize 语义：
  - `single` 在拿到完整结果后一次性提交最终内容
  - `streaming` 在增量 flush 后正常收尾

### 实施注意事项

- 本 stage 不做 parser 和 renderer，只把“session 怎么建、何时 flush、配置从哪里读”实际接入。
- 不允许 transport、renderer、prompt 各自读各自的 `streaming` 配置解释。
- findings 只写执行边界，不写成长散文。

### 本 stage 验收

- 仓库里已经有统一的 `streaming` config 入口。
- runtime snapshot、InboundWorker、transport session 对 `single` / `streaming` 的理解一致。
- reviewer 能直接看到 `single` 不是“无 session”，而是“无正文增量 flush”。
- Stage 4 不需要再重复修改 config / runtime snapshot / InboundWorker / Transport plumbing。

### 本 stage 验证

- 新增或更新测试覆盖：
  - `single` 仍创建 session，但不在正文阶段 patch / publish assistant 增量
  - `streaming` 会在正文阶段 patch / publish assistant 增量
- 运行：
  - `mix test test/nex/agent/inbound_worker_test.exs`
  - `mix test test/nex/agent/stream/streaming_config_test.exs`

## Stage 2

### 前置检查

- Stage 1 已冻结 `single` / `streaming` flush policy。
- 读清当前 `FeishuSession` / `MultiMessageSession` 的收尾与 flush 逻辑。
- 读清当前 `Feishu.build_interactive_card/1` 的 markdown 转卡片路径。

### 这一步改哪里

- 新增 `lib/nex/agent/im_ir/parser.ex`
- 新增 `lib/nex/agent/im_ir/block.ex`
- 新增 `lib/nex/agent/im_ir/render_result.ex`
- 新增 `lib/nex/agent/im_ir/profiles/feishu.ex`
- 需要时新增 `lib/nex/agent/im_ir.ex`
- 新增 `test/nex/agent/im_ir/parser_test.exs`
- 新增 `test/nex/agent/im_ir/render_result_test.exs`

### 这一步要做

- 定义平台文本 IR parser 的内部边界：
  - 输入：字符串或字符串增量
  - 输出：内部 block / `RenderResult`
- 冻结 parser 最小内部块结构，作为实现细节使用：
  - `:paragraph`
  - `:heading`
  - `:list`
  - `:quote`
  - `:code_block`
  - `:table`
  - `:new_message`
- 明确 parser 是可增量解析的：
  - `new/1`
  - `push/2`
  - `flush/1`
  - 允许内部 combinator 组合
- 落地 `Nex.Agent.Interface.IMIR.RenderResult` 最小 shape：
  - `payload`
  - `text`
  - `complete?`
  - `new_message?`
  - `canonical_text`
  - `warnings`
- 定义 Feishu 平台 IR parser 规则骨架：
  - `<newmsg/>` 单独成 token
  - fenced code block 保持原文
  - table block 保持行级信息
- 明确 canonical content 规则：
  - parser / renderer 过程不得从 `final_content` 中删除 `<newmsg/>`
  - parser / renderer 过程不得把平台 payload 反写成 canonical content
  - `final_content` 保留模型原始平台文本 IR

### 实施注意事项

- 这一 stage 的 block struct 只是内部实现，不得变成新的外部 API。
- 不允许在 parser 对外接口暴露一堆开关参数。
- parser 必须能处理 chunk 边界落在 `<newmsg/>` / code fence / table 分隔线中的情况。
- `<newmsg/>` 的输出是内部结构，不要求变成跨平台公共 action 契约。
- `RenderResult` 是内部 handoff，不得被 `ContextBuilder` 或 tool schema 暴露给模型。

### 本 stage 验收

- 仓库里存在独立 parser pipeline 骨架，而不是继续在 channel 模块中堆正则。
- parser 单独可测，能增量识别 `<newmsg/>` 与代码块边界。
- `RenderResult` shape 已有单测固定。
- canonical `final_content` 规则已有单测固定。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/im_ir/parser_test.exs`
  - `mix test test/nex/agent/im_ir/render_result_test.exs`

## Stage 3

### 前置检查

- Stage 2 parser 已能增量产出内部块。
- 读清当前 Feishu channel 的 `build_interactive_card/1`、`render_chunk/1`、`do_patch_card/3`。
- 确认当前 live 主链仍使用 Feishu edit-message session。

### 这一步改哪里

- 新增 `lib/nex/agent/im_ir/renderers/feishu.ex`
- 更新 `lib/nex/agent/channel/feishu.ex`
- 更新 `lib/nex/agent/stream/feishu_session.ex`
- 更新 `test/nex/agent/channel_feishu_test.exs`
- 需要时新增 `test/nex/agent/im_ir/feishu_renderer_test.exs`

### 这一步要做

- 把 Feishu 正文渲染从“弱 markdown 转卡片”迁到“Feishu 文本 IR -> Feishu payload renderer”。
- renderer 至少支持：
  - paragraph -> Feishu div / md text
  - heading -> Feishu 强调样式
  - list -> Feishu 可显示列表
  - quote -> Feishu 可显示引用
  - code_block -> Feishu 可显示代码块
  - table -> Feishu 可显示的近似结构
- `FeishuSession` 不再直接依赖原始 `visible_text` 做最终平台转换。
  - 应该持有当前文本 IR 缓冲和当前平台 payload 表示
- `<newmsg/>` 在 Feishu 的处理规则要冻结清楚：
  - 若当前 Feishu policy 允许切多条，则新建新 card message
  - 若当前 Feishu policy 不允许切多条，则按该平台固定降级规则处理

### 实施注意事项

- 本 stage 不要求 Feishu table 渲染达到“完美原生表格”；但不得继续默默丢掉表格结构。
- 代码块与表格的转换必须是确定性的，不做智能猜测。
- `<newmsg/>` 在代码块中不得切消息。
- 若 Feishu 某类块最终只能降级为纯文本，必须在测试里显式固定该降级行为。

### 本 stage 验收

- Feishu 主路径不再依赖当前脆弱的字符串切行 renderer 作为唯一正文方案。
- 代码块和表格已有稳定 renderer 或稳定降级。
- `<newmsg/>` 已有稳定 Feishu 处理规则，而不是留给调用方猜。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/channel_feishu_test.exs`
  - `mix test test/nex/agent/im_ir/feishu_renderer_test.exs`

## Stage 4

### 前置检查

- Stage 3 Feishu renderer 已可用。
- Stage 1 的 `streaming` config、runtime snapshot、session flush policy 已接入。
- 明确 Stage 4 不重复修改 config / runtime snapshot / InboundWorker / Transport plumbing。

### 这一步改哪里

- 更新 `lib/nex/agent/stream/feishu_session.ex`
- 更新 `lib/nex/agent/stream/multi_message_session.ex`
- 更新 `test/nex/agent/runner_stream_test.exs`
- 更新或新增：
  - `test/nex/agent/stream/new_message_boundary_test.exs`

### 这一步要做

- 在 `single` 与 `streaming` 下都验证 `<newmsg/>`：
  - `single`: 完整文本解析后按平台规则发送多段或降级
  - `streaming`: 增量解析时按平台规则切段或降级
- 固定 Feishu 对 `<newmsg/>` 的第一版策略：
  - 如果 Feishu 允许当前 session 连续发多条 card，则真切新 card
  - 如果不允许，则降级为同一 card 内的固定分隔块
- 固定 MultiMessage fallback 对 `<newmsg/>` 的第一版策略：
  - 如果 channel 支持连续普通消息，则发布下一条消息
  - 如果 channel 限制连续消息，则按固定分隔文本降级

### 实施注意事项

- 不得在本 stage 重新定义 `single` / `streaming` config。
- 不得让 `<newmsg/>` 变成新的 runtime config 或 mode。
- 不支持多条消息的平台可以对 `<newmsg/>` 降级，但必须固定规则，不允许 silent drift。

### 本 stage 验收

- `<newmsg/>` 在两种模式下都有明确测试覆盖。
- Feishu 和 MultiMessage fallback 都有明确 `<newmsg/>` 策略。
- `finalize_success/2` 不会把 `<newmsg/>` 处理后的用户可见多段内容反向合并覆盖为单条用户消息。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/runner_stream_test.exs`
  - `mix test test/nex/agent/stream/new_message_boundary_test.exs`

## Stage 5

### 前置检查

- Stage 1 的 runtime config 与 Stage 4 的 session 行为已就位。
- 读清当前 `ContextBuilder` 对 Feishu 的 runtime guidance。
- 确认当前 prompt 里已经允许按 channel 注入运行时规则。

### 这一步改哪里

- 更新 `lib/nex/agent/context_builder.ex`
- 需要时更新 `lib/nex/agent/runtime/snapshot.ex`
- 更新相关 prompt 测试或新增：
  - `test/nex/agent/context_builder_test.exs`

### 这一步要做

- 为当前 channel 注入平台文本 IR 说明。
- 为当前 channel 注入 `streaming` 说明。
- 对 Feishu 第一版明确写清：
  - 允许输出哪些块
  - 不要输出哪些无法稳定渲染的形态
  - `<newmsg/>` 如何使用
  - 代码块与表格的写法要求
- 若 channel 没有专属平台 IR，回退到普通 markdown guidance。

### 实施注意事项

- prompt 说明必须短而硬，不要写成长教学文。
- 不要把 parser 实现细节暴露给模型，只写它应该输出什么。
- 本 stage 只负责生成约束，不负责“提示词魔法修复 renderer 缺陷”。

### 本 stage 验收

- 运行时 prompt 已能明确区分不同 channel 的文本 IR 规则。
- reviewer 能直接看到 `<newmsg/>` 与 `streaming` 的模型侧约束来源。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/context_builder_test.exs`

## Stage 6

### 前置检查

- Stage 3、4、5 已全部落地。
- 当前 live Feishu gateway 可用于人工验证。

### 这一步改哪里

- 更新 `docs/dev/task-plan/index.md`
- 更新 `docs/dev/progress/CURRENT.md`
- 更新当日 progress log
- 需要时补 findings / progress 引用

### 这一步要做

- 补 phase4 索引入口。
- 在 `CURRENT.md` 里把 phase4 写成当前主线。
- 记录 reviewer 需要看的最小验证命令和手工 smoke flow：
  - Feishu `single`
  - Feishu `streaming`
  - 代码块
  - 表格
  - `<newmsg/>`
- 记录明确非目标：
  - 本 phase 不要求所有平台同日落地
  - 本 phase 不做重型公共 IR
  - 本 phase 不为平台原生 JSON 再开正文主链接口

### 实施注意事项

- 不要把 `CURRENT.md` 写成 changelog。
- 只保留后续执行者继续推进所需的最小上下文。

### 本 stage 验收

- phase4 已进入 task plan index 和 current mainline。
- reviewer 可直接按文档命令验证。

### 本 stage 验证

- 人工检查：
  - `docs/dev/task-plan/index.md`
  - `docs/dev/progress/CURRENT.md`

## Review Fail 条件

- 把平台文本 IR 重新抽象成跨平台公共重型 AST 对外 contract。
- 对外新增一堆 converter feature flags，破坏“接口是字符串”的边界。
- 把 `single` 误实现成“无 session”，而不是“无正文增量 flush”。
- `<newmsg/>` 被重新做成单独的 message mode 或 feature flag。
- `<newmsg/>` 在代码块内误切消息。
- Feishu 继续把代码块、表格完全当普通段落字符串处理而没有稳定 renderer / 稳定降级。
- phase4 文档只写设计方向，没有 stage、实施位置、验收和验证。
