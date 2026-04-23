---
name: stream-transport-error-partial-content-loss
description: LLM stream 中途 TransportError 导致 partial content 丢失，重试从头开始而非续写
type: project
---

LLM provider 在 stream 过程中关闭 TCP 连接（`Mint.TransportError{reason: :closed}`）时，已收到的 partial content 会丢失，重试从头开始。

**Why:** `call_llm_with_retry` 的重试逻辑在 stream 开始前生效；一旦进入 `Enum.reduce(response.stream, ...)` 后出错，partial content 不会被保留传递给重试。对于长回复（如 upgrade_code 的结果），用户看到截断的消息 + error 尾巴。

**How to apply:**
- 改进点 1：stream 中途失败时保留 partial content，重试用 `continue` prompt 让 LLM 从断点续写
- 改进点 2：`apply_discord_converter_event` 静默丢弃 mid-stream error 本身没问题（finalize 兜底），但如果 finalize 也失败用户看不到任何错误提示，可加 fallback
- 关键文件：`lib/nex/agent/llm/req_llm.ex`（stream 收集）、`lib/nex/agent/runner.ex:835`（重试逻辑）、`lib/nex/agent/inbound_worker.ex:1628`（error 事件处理）
- 2026-04-23 在 Discord E2E 测试中首次观察到，provider 是 api.aicodemirror.com
