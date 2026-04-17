# 2026-04-16 IM Text IR And Renderer Pipeline

## Stage 1 Frozen Boundaries

- 平台正文对模型继续保持 `String.t()` contract。
- `streaming` 是 per-channel runtime config，不是 parser / renderer 外部 feature flag。
- `single` 与 `streaming` 都创建 session。
- `single` 的语义是：
  - 先建 session
  - 可发送占位态
  - assistant 正文阶段不增量 flush
  - 完整结果出来后一次性 finalize
- `streaming` 的语义是：
  - 先建 session
  - 可发送占位态
  - assistant 正文阶段允许增量 flush
  - 结束时正常 finalize
- runtime snapshot、InboundWorker、transport session 必须共用同一份 channel `streaming` 配置解释。
- 本 stage 不引入 parser、renderer、`<newmsg/>` 行为实现，只冻结 session / flush policy 主链。

## Stage 1 Implementation Notes

- `Nex.Agent.Config` 新增统一 channel runtime 读取入口，输出最小 `streaming` shape。
- `Nex.Agent.Runtime.Snapshot` 暴露 `channels`，让 transport 与后续 prompt 读取同一份 runtime channel 配置。
- `InboundWorker` 在打开 stream session 时传入：
  - `metadata`
  - `channel_runtime`
- session 自己根据 `channel_runtime["streaming"]` 决定是否在 `:text_delta` 阶段 flush。
- finalize 仍由 session 负责：
  - `single` 一次性提交最终内容
  - `streaming` 在已有增量 flush 后正常收尾
