# Current Mainline

## Active Workstream

Phase 1 runtime reload foundation is implemented. Phase 3 streaming delivery and Phase 3A architecture convergence are in place. Phase 4 is now closed as the text-IR foundation, Phase 4A is superseded, Phase 5 IM inbound architecture and media projection is implemented, and Phase 7 Feishu streaming converter simplification is now the active mainline. Phase 6 Feishu outbound official format/media send remains landed, but the active architecture correction is now phase7.

## Why This Is Active

Phase 1 replaced the previously split behavior:

- `Nex.Agent.Runtime` now publishes a unified snapshot containing config, prompt, tool definitions, skills, workspace, version, and changed paths.
- Main request paths now pass runtime snapshot prompt/tools/config into `Runner`, `InboundWorker`, `Nex.Agent`, and `Gateway`.
- In-memory cached agents now carry `runtime_version` and are rebuilt on the next user turn when stale.
- A minimal polling watcher reloads runtime inputs and refreshes skills/tools before publishing a new runtime version.
- A runtime reconciler updates channel children through `Gateway.reconcile/1` without full Gateway restart.

Live channel reconnect behavior should still be watched under real credentials, but the repository has the phase 1 reload foundation and tests in place.

Phase 4 resolved the first user-visible rendering blocker instead of leaving it as channel-private heuristics:

- per-channel `streaming` config is now a unified runtime contract shared by snapshot, prompt, InboundWorker, and transport session.
- the repo now has an internal IM text IR parser boundary with frozen block shapes and `RenderResult`.
- Feishu interactive cards now render through the IM IR pipeline instead of the previous weak markdown chunker.
- `<newmsg/>` now has a first fixed policy:
  - Feishu: degrade to an in-card separator
  - multi-message channels: split final user-visible messages on finalize
- runtime prompt guidance now tells the model which channel IR and streaming mode are active.

That work exposed a larger follow-up that should not stay inside phase4:

- inbound media currently enters the model through a thin `metadata["media"] -> ContextBuilder` image-only path
- media still lacks a unified attachment/store/projection layer
- Feishu official outbound format and media send should build on top of that attachment layer, not race ahead with new channel-private lifecycle logic

Phase 5 is now the completed inbound/media foundation:

- architecture is multi-channel from day one
- implementation first-path is Feishu only
- inbound media now enters the model through:
  - `%Nex.Agent.Inbound.Envelope{}`
  - `%Nex.Agent.Media.Ref{}`
  - hydrated `%Nex.Agent.Media.Attachment{}`
  - provider-facing projection from `ContextBuilder` / `ReqLLM`

Phase 6 established the current Feishu outbound baseline:

- Feishu outbound now has a first unified outbound request boundary
- `message` tool no longer depends on an image-only private send path internally
- Feishu media send now materializes attachments into native image/file/audio/media payloads
- default Feishu card send / patch / streaming now share an explicit card-builder boundary
- but it also exposed a larger architecture mistake in streaming:
  - Feishu streaming is currently burdened by extra event/action/session abstractions
  - `<newmsg/>` still fails as a true streaming boundary
  - the current mainline needs a direct converter-based streaming rewrite, not more local patching

Phase 7 is now the active workstream:

- delete the current over-generalized streaming middle layer for Feishu
- restore the correct main model:
  - `LLM text stream -> stateful converter -> Feishu API`
- make the converter itself own:
  - active card
  - sequence
  - pending buffer
  - `<newmsg/>` boundary detection
- the hard acceptance bar is now:
  - Feishu streaming multi-message works correctly under real credentials

## Current Plan Pointer

- [Phase 1 Runtime Reload Foundation](../task-plan/phase1-runtime-reload-foundation.md)
- [Phase 3 Streaming Delivery Contract](../task-plan/phase3-streaming-delivery-contract.md)
- [Phase 3A Streaming Architecture Convergence](../task-plan/phase3a-streaming-architecture-convergence.md)
- [Phase 4 IM Text IR And Renderer Pipeline](../task-plan/phase4-im-text-ir-and-renderers.md)
- [Phase 4A Feishu Native Capabilities And Media](../task-plan/phase4a-feishu-native-capabilities-and-media.md)
- [Phase 5 IM Inbound Architecture And Media Projection](../task-plan/phase5-im-inbound-architecture-and-media-projection.md)
- [Phase 6 Feishu Outbound Official Format And Media Send](../task-plan/phase6-feishu-outbound-official-format-and-media-send.md)
- [Phase 7 Feishu Streaming Converter Simplification](../task-plan/phase7-feishu-streaming-converter-simplification.md)
- [2026-04-16 IM Inbound Media Architecture](../findings/2026-04-16-im-inbound-media-architecture.md)
- [2026-04-16 IM Streaming Capabilities And Delivery Contract](../findings/2026-04-16-im-streaming-capabilities.md)
- [2026-04-16 Streaming Architecture Convergence](../findings/2026-04-16-streaming-architecture-convergence.md)
- [2026-04-16 Streaming Phase4 Polish](../findings/2026-04-16-streaming-phase4-polish.md)
- [2026-04-17 Feishu Streaming Converter Boundary](../findings/2026-04-17-feishu-streaming-converter-boundary.md)
- [2026-04-16 OpenAI Native Computer Use Architecture](../findings/2026-04-16-openai-native-computer-use-architecture.md)

## Immediate Next Steps

1. **修 Finch 连接池泄漏**（P0）：并发为 1 时 `excess queuing for connections`。排查 `ReqLLM` streaming 连接释放——可能是 streaming response body 没消费完导致 Finch 持有连接不归还。
2. **修飞书 `close_streaming_mode` 404**：对照飞书 CardKit 文档确认 `PATCH /cardkit/v1/cards/:card_id/settings` 的正确路径和请求格式。
3. **LLM 空返回兜底**：当 `final_content` 为空时发 fallback 消息，避免 bot 沉默。
4. 后续可返回 [Phase 6 Feishu Outbound Official Format And Media Send](../task-plan/phase6-feishu-outbound-official-format-and-media-send.md)。

## Reviewer Verification

- `mix test test/nex/agent/channel_feishu_test.exs`
- `mix test test/nex/agent/channel/feishu_stream_converter_test.exs`
- `mix test test/nex/agent/channel_discord_test.exs`
- `mix test test/nex/agent/inbound_worker_test.exs`
- `mix test test/nex/agent/message_tool_test.exs`

## Explicit Non-Goals For The Current Mainline

- Zero-downtime websocket resume across every provider in phase 1
- Reworking session persistence format
- Converting every doc into the new structure in one pass
- Telegram / Discord / Slack / DingTalk outbound media parity during Feishu phase6

## Parked Architecture Work

- OpenAI native computer use has an architecture decision record, but it is not part of the current runtime-reload mainline.
- Any future implementation should follow the provider-native item orchestration path in [2026-04-16 OpenAI Native Computer Use Architecture](../findings/2026-04-16-openai-native-computer-use-architecture.md) instead of adding fake browser function tools to `Tool.Registry`.
- Slack native stream and Telegram/Discord edit adapters are intentionally not part of Phase 3A; Phase 3A exists to make those follow-on integrations land on cleaner boundaries.
