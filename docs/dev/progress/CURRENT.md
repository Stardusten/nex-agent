# Current Mainline

## Active Workstream

Phase 1 runtime reload foundation is implemented. Phase 3 streaming delivery and Phase 3A architecture convergence are in place. Phase 4 is now closed as the text-IR foundation, Phase 4A is superseded, Phase 5 IM inbound architecture and media projection is implemented, and Phase 7 Feishu streaming converter simplification is in place. Phase 8 session run control and busy follow-up is landed, and Phase 9 follow-up LLM turn and interrupt request is now landed on top of it. Phase 6 Feishu outbound official format/media send remains landed.

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

Phase 7 established the current Feishu streaming correction:

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

Phase 8 established the current session control baseline:

- add explicit session busy / idle state
- ensure each session has at most one owner run
- make busy ordinary messages default to follow-up turns, not owner run interruption
- keep `/stop` as deterministic hard control that does not depend on LLM/tool choice
- add `/queue`, `/btw`, and `/status` as user control commands
- make cancellation run-id based so stale owner run results cannot write back after stop
- push cancellation down into Runner / Tool.Registry / long tools so heavy logic can be stopped promptly

Phase 9 tightened the follow-up path on top of Phase 8:

- replace deterministic busy follow-up replies with a real follow-up LLM turn
- reuse the current owner snapshot instead of introducing a new event/state subsystem
- reuse `Nex.Agent.prompt/3` with `skip_consolidation: true` and `tools_filter: :follow_up`
- keep `/stop` deterministic while allowing an optional thin follow-up interrupt tool that reuses the same control lane
- keep follow-up tools frozen to the minimal read-only surface plus the thin interrupt tool
- prevent follow-up turns from inheriting skill runtime ephemeral tools

Phase 10/11 planning now defines the self-iteration direction beyond session control:

- Phase 10d/e/f establish the CODE-layer self-update mainline:
  - code discovery/editing flows through `find -> read/reflect -> apply_patch`
  - runtime activation flows only through `self_update status/deploy/rollback`
  - release visibility, rollback candidates, quick deploy checks, and owner/subagent handoff are explicit
- Phase 11 is the self-healing driver plan:
  - this is exploratory, not a one-shot refactor
  - first priority is a low-cost, budget-driven minimal loop that can observe failures and produce structured signals
  - self-healing is split into hot-path deterministic recovery, near-path bounded reflection, and long-path evolution
  - an energy/metabolism ledger controls how often and how deeply the agent may self-iterate
- Phase 11A is the first executable step:
  - only `tool.call.failed`, `llm.call.failed`, and `self_update.deploy.failed` are in scope
  - no LLM reflection, memory writes, skill drafts, patch generation, or deploy automation in 11A
  - output is durable structured events, cheap aggregation, and bounded router decisions
  - the first implementation is now in place: event store, energy ledger, aggregator, router, Runner hooks, self_update deploy failure hook, prompt/onboarding guidance, and focused tests

Phase 12 now establishes the LLM provider adapter boundary:

- provider-specific LLM behavior should live in independent adapter modules
- `ReqLLM` should stay on a provider-agnostic facade and never import concrete provider modules
- `ProviderProfile` is now the profile struct/facade/registry dispatch point, not the place where provider policy accumulates
- known provider behavior now lives under `Nex.Agent.LLM.Providers.*` adapters registered by `ProviderRegistry`
- thin adapters only implement behavior that differs from the default adapter fallback
- provider 默认模型选择归 adapter/facade 所有，`ReqLLM` 不维护 provider-specific default model 分支
- `openai-codex` OAuth is the first concrete forcing function:
  - ChatGPT Codex backend owns a provider-specific Responses payload policy
  - that policy lives under the OpenAI Codex provider adapter namespace
  - third-party codex-compatible API key routes must remain independent

Phase 13 planning now defines the Control Plane observability direction:

- structured observation is the machine source of truth; human text logs are projections, not primary agent state
- `context` is only for correlation identity such as workspace/run/session/channel/tool call; domain data belongs in `attrs`
- the necessary API surface is `ControlPlane.Log`, `Metric`, `Gauge`, `Budget`, `Store`, `Query`, and one agent-facing `observe` tool
- Phase 13A is now implemented as the first cutover:
  - `Nex.Agent.ControlPlane.{Store,Redactor,Query,Log,Metric,Gauge,Budget}` is in place with JSONL observations and gauge/budget state under workspace `control_plane/`
  - `observe` is the single agent-facing query tool and is exposed on `:all`, `:base`, and `:follow_up`
  - Phase 11A `SelfHealing.EventStore` / `EnergyLedger` are deleted; Runner, SelfUpdate, and the minimal router use ControlPlane observations/budget for the three 11A failure classes
- Phase 13B is now implemented for runtime lifecycle observability:
  - Runner emits run, LLM call, tool batch, tool call, and tool task lifecycle observations.
  - Tool.Registry emits deterministic execution started/finished/failed/cancelled observations.
  - HTTP emits request started/finished/failed/timeout/cancelled observations, strips Nex internal opts before Req, and converts request task exceptions to structured errors.
  - SelfUpdate deploy emits started/finished/failed observations under the same ControlPlane store.
- Phase 13C is now implemented for run-control and follow-up observability:
  - RunControl emits `run.owner.*` lifecycle observations and projects active owner runs into workspace-level `run.owner.current` gauge.
  - InboundWorker emits inbound, owner dispatch, follow-up, queue, interrupt, status, timeout, and crash observations.
  - `/status` remains deterministic and now appends recent ControlPlane warning/error evidence for the current run/session.
  - Follow-up prompts require `observe summary` / `observe incident` before answering error, stuck, backend, log, status, or incident questions.
- Phase 13D is now implemented for semantic log and Admin query cutover:
  - Production code no longer calls `Audit.*` / `RequestTrace.*` as machine truth sources; remaining modules are ControlPlane compatibility wrappers.
  - `Audit.append/3` writes `ControlPlane.Log` observations and publishes observation summaries instead of `audit/events.jsonl`.
  - `RequestTrace.append_event/2`, `list_paths/1`, and `read_trace/2` are ControlPlane-derived and do not write or read request trace JSONL files.
  - Admin recent events and request trace detail read `ControlPlane.Query` summaries/run traces, aligning Admin with `observe`.
  - Runner request trace compatibility observations store bounded summaries only, not full prompts, messages, responses, or tool results.
  - Direct `Logger.*` files are captured by `control_plane_logger_cutover_test.exs` as an explicit reviewed allowlist.

## Current Plan Pointer

- [Phase 1 Runtime Reload Foundation](../task-plan/phase1-runtime-reload-foundation.md)
- [Phase 3 Streaming Delivery Contract](../task-plan/phase3-streaming-delivery-contract.md)
- [Phase 3A Streaming Architecture Convergence](../task-plan/phase3a-streaming-architecture-convergence.md)
- [Phase 4 IM Text IR And Renderer Pipeline](../task-plan/phase4-im-text-ir-and-renderers.md)
- [Phase 4A Feishu Native Capabilities And Media](../task-plan/phase4a-feishu-native-capabilities-and-media.md)
- [Phase 5 IM Inbound Architecture And Media Projection](../task-plan/phase5-im-inbound-architecture-and-media-projection.md)
- [Phase 6 Feishu Outbound Official Format And Media Send](../task-plan/phase6-feishu-outbound-official-format-and-media-send.md)
- [Phase 7 Feishu Streaming Converter Simplification](../task-plan/phase7-feishu-streaming-converter-simplification.md)
- [Phase 8 Session Run Control And Busy Follow-up](../task-plan/phase8-session-run-control-and-followup.md)
- [Phase 9 Follow-up LLM Turn And Interrupt Request](../task-plan/phase9-follow-up-llm-turn-and-interrupt-request.md)
- [Phase 10 Self-Iteration Foundation](../task-plan/phase10-self-iteration-foundation.md)
- [Phase 10d Self-Update Deploy Control Plane](../task-plan/phase10d-self-update-deploy-control-plane.md)
- [Phase 10e Code Editing Toolchain Reset](../task-plan/phase10e-code-editing-toolchain-reset.md)
- [Phase 10f Self-Iteration UX And Release Visibility](../task-plan/phase10f-self-iteration-ux-and-release-visibility.md)
- [Phase 11 Self-Healing Driver](../task-plan/phase11-self-healing-driver.md)
- [Phase 11A Minimal Self-Healing Loop](../task-plan/phase11a-minimal-self-healing-loop.md)
- [Phase 12 LLM Provider Adapter Architecture](../task-plan/phase12-llm-provider-adapter-architecture.md)
- [Phase 13 Control Plane Observability](../task-plan/phase13-control-plane-observability.md)
- [Phase 13A Minimal Control Plane Observability Cutover](../task-plan/phase13a-minimal-control-plane-observability-cutover.md)
- [Phase 13B Control Plane Runtime Lifecycle Observability](../task-plan/phase13b-control-plane-runtime-lifecycle-observability.md)
- [Phase 13C Run Control And Follow-Up Observability](../task-plan/phase13c-run-control-follow-up-observability.md)
- [Phase 13D Semantic Log And Admin Query Cutover](../task-plan/phase13d-semantic-log-and-admin-query-cutover.md)
- [Phase 13E Evolution Control Plane Consumption](../task-plan/phase13e-evolution-control-plane-consumption.md)
- [Phase 14 Owner-Approved Evolution Execution](../task-plan/phase14-owner-approved-evolution-execution.md)
- [Phase 15 Provider-Native Tool Capability Resolution](../task-plan/phase15-provider-native-tool-capability-resolution.md)
- [2026-04-16 IM Inbound Media Architecture](../findings/2026-04-16-im-inbound-media-architecture.md)
- [2026-04-16 IM Streaming Capabilities And Delivery Contract](../findings/2026-04-16-im-streaming-capabilities.md)
- [2026-04-16 Streaming Architecture Convergence](../findings/2026-04-16-streaming-architecture-convergence.md)
- [2026-04-16 Streaming Phase4 Polish](../findings/2026-04-16-streaming-phase4-polish.md)
- [2026-04-17 Feishu Streaming Converter Boundary](../findings/2026-04-17-feishu-streaming-converter-boundary.md)
- [2026-04-16 OpenAI Native Computer Use Architecture](../findings/2026-04-16-openai-native-computer-use-architecture.md)

## Immediate Next Steps

1. 优先进入 Phase 15：建立 capability-resolved tool 主链，把 `web_search` 从“静态 local tool + Codex 特判 rewrite”迁到统一 resolver，至少支持 `openai-codex` 官方 OAuth backend 的 native search。
2. 在 Phase 15 中同时收口 `ProviderProfile.default_api_key(:openai_codex)` facade 偏差，确保 provider profile 真相源与 `Auth.Codex.resolve_access_token/0` 对齐。
3. Phase 15 完成后，再补真实 gateway/manual 验证，确认 capability resolution 在实际 workspace 上不会泄漏 parallel definitions，且 `web_search` 在不同 provider / surface 下行为一致。
4. 跑更完整的 channel 回归：`test/nex/agent/channel_discord_test.exs`、`test/nex/agent/channel_feishu_test.exs`。
5. 用真实 gateway/manual 场景检查 busy 普通消息 follow-up、`/btw`、`/status`、`/stop`、可选 interrupt tool，以及 follow-up 使用 `observe summary` 的实际交互时序。
6. Phase 7 留存问题仍需后续处理：Finch 连接池泄漏、飞书 `close_streaming_mode` 404、LLM 空返回兜底。

## Reviewer Verification

- `mix test test/nex/agent/channel_feishu_test.exs`
- `mix test test/nex/agent/channel/feishu_stream_converter_test.exs`
- `mix test test/nex/agent/channel_discord_test.exs`
- `mix test test/nex/agent/inbound_worker_test.exs`
- `mix test test/nex/agent/message_tool_test.exs`
- `mix test test/nex/agent/run_control_test.exs`
- `mix test test/nex/agent/bash_tool_test.exs`
- `mix test test/nex/agent/runner_stream_test.exs`

## Explicit Non-Goals For The Current Mainline

- Zero-downtime websocket resume across every provider in phase 1
- Reworking session persistence format
- Converting every doc into the new structure in one pass
- Telegram / Discord / Slack / DingTalk outbound media parity during Feishu phase6

## Parked Architecture Work

- OpenAI native computer use has an architecture decision record, but it is not part of the current runtime-reload mainline.
- Any future implementation should follow the provider-native item orchestration path in [2026-04-16 OpenAI Native Computer Use Architecture](../findings/2026-04-16-openai-native-computer-use-architecture.md) instead of adding fake browser function tools to `Tool.Registry`.
- Slack native stream and Telegram/Discord edit adapters are intentionally not part of Phase 3A; Phase 3A exists to make those follow-on integrations land on cleaner boundaries.
