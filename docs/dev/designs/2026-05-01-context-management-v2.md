# Context Management V2

## 背景

2026-05-01 的 Discord / Xiaohongshu OCR 现场暴露了当前上下文管理的两个硬缺口：

- `gpt-5.5-xhigh-fast` 在第三轮 LLM 调用返回 `finish_reason="incomplete"`、空 content、无 tool call；Runner 把它记录为 `ok` 并最终发出空消息。
- `/model` 显示的 owner run 实际走 `openai_codex / gpt-5.5`，日志里看到的 `deepseek-v4-flash` 属于后续 memory refresh / consolidation，不是该用户消息的主模型。
- 当时第三轮投影观测为 `message_count=28`、`content_chars=117058`、`tool_call_messages=8`、`context_window=250000`。以现有 `chars / 4` 估算约 29k tokens，不能证明是输入本身超过 250k context。

当前 `Nex.Agent.Turn.ContextWindow` 已经是本项目的上下文投影边界，但它仍是第一版：

- token 估算只做 `text_size / 4`；
- 只在初始 prompt 构建时选择 history；
- 不保存 provider 回包里的 token usage 作为后续锚点；
- 不把 `incomplete_details`、usage、context-window projection 统一成可查询状态；
- 对 `finish_reason="incomplete"` 没有错误语义，Runner 会把空响应当成功。

Codex 源码的方向值得借鉴：它不是每次都用 tokenizer 精确重算全量上下文，而是用 API 回包 usage 做锚点，再对上次成功回包之后新增的本地 items 用 byte/token heuristic 估算，并用 model metadata 的 context window / auto compact threshold 驱动 compaction。

## 目标

把上下文管理升级为一个可观测、可恢复、可迭代的 CODE 层主链：

1. `ContextWindow` 继续是唯一的 LLM 输入窗口投影边界。
2. token usage 以 provider 回包 usage 为权威锚点，缺失时才退回本地估算。
3. 本地估算从 `chars / 4` 升级为可替换 estimator，并区分 text、tool output、tool schema、media projection、reasoning carryover。
4. 每轮 LLM 调用前后都更新上下文 ledger，而不是只在首轮选择 history。
5. `incomplete` 成为明确的 LLM 非成功状态，记录原因、usage、投影快照，并触发可控重试或用户可理解的失败。
6. OpenAI Codex native compaction 仍只是 provider-specific payload policy；NexAgent 自己的真相源不退化成 provider 私有会话。

## 非目标

- 不在第一阶段引入 provider-specific tokenizer 作为硬依赖。
- 不把 session history 改造成 OpenAI Responses 原生 item store。
- 不让 provider adapter 或 Runner 各自维护一套 context trimming。
- 不把 memory / consolidation 当成解决当前 turn context overflow 的隐式兜底。
- 不为了中间状态兼容保留旧 `chars / 4` contract；实现阶段应通过编译错误迁移调用点。

## 设计原则

### 单一真相源

上下文窗口选择、token ledger、native compaction projection、tool output 截断都归 `Nex.Agent.Turn.ContextWindow` 这一条 CODE 主链。Runner 只编排：

```text
session + runtime model metadata + current user turn
-> ContextWindow.project_request/...
-> ContextBuilder.build_messages(...)
-> ReqLLM.stream(...)
-> ContextWindow.record_response(...)
```

Provider adapter 只负责把已经投影好的 metadata 翻译成 provider payload 字段，例如 OpenAI Codex 的 `context_management` 和 `context_compaction_items`。

### Usage Anchor 优先

若 provider 回包包含 usage，使用 usage 更新 ledger。若没有 usage，则记录 estimator-only projection，并在 ControlPlane 标记 `usage_source="estimate"`。

这与 Codex 的核心模式一致：

- 已完成 API 响应的 token usage 由服务端回包锚定；
- 上次成功响应之后本地新增的 user/tool/assistant items 用启发式估算补足；
- 当 history 被 compaction 或 rollback 改写时，ledger 必须显式重算或降级为 estimate-only。

### 投影和记账分离

`ContextWindow` 需要拆出四个职责，但仍属于同一上下文管理器边界：

- `Spec`：解析 model runtime 的 `context_window`、`auto_compact_token_limit`、`context_strategy`、output reserve。
- `Ledger`：保存每个 session/model 的最近 usage anchor、估算增量、投影版本和 incomplete 证据。
- `Estimator`：对本地 message / tool result / media / tool schema / runtime prompt 做可替换估算。
- `Projector`：根据 spec + ledger + estimator 选择 history、截断 tool output、注入 native compaction items。

## Proposed Modules

```text
lib/nex/agent/turn/context_window.ex
lib/nex/agent/turn/context_window/spec.ex
lib/nex/agent/turn/context_window/ledger.ex
lib/nex/agent/turn/context_window/estimator.ex
lib/nex/agent/turn/context_window/projector.ex
lib/nex/agent/turn/context_window/failure.ex
```

`context_window.ex` 保持 facade，避免 Runner 依赖内部模块。

## Data Shapes

### Context Spec

```elixir
%Nex.Agent.Turn.ContextWindow.Spec{
  provider: :openai_codex,
  model: "gpt-5.5",
  model_key: "gpt-5.5-xhigh-fast",
  context_window: 250_000,
  effective_context_window: 237_500,
  auto_compact_token_limit: 225_000,
  output_token_reserve: 4_096,
  safety_margin_tokens: 4_096,
  context_strategy: "server_side_then_recent",
  native_compaction?: true,
  usage_accounting: :server_anchor_then_estimate
}
```

`effective_context_window` 默认可按 provider metadata 或本地策略从 `context_window` 派生；没有 provider metadata 时先用 95%。

### Token Usage

```elixir
%Nex.Agent.Turn.ContextWindow.TokenUsage{
  input_tokens: non_neg_integer(),
  cached_input_tokens: non_neg_integer(),
  output_tokens: non_neg_integer(),
  reasoning_output_tokens: non_neg_integer(),
  total_tokens: non_neg_integer(),
  source: :provider | :estimate | :mixed,
  raw: map() | nil
}
```

Provider adapter / `ReqLLM` 负责把 OpenAI / Anthropic / compatible usage normalize 到这组字段。原始 provider 字段可放 `raw`，但日志和 ControlPlane 只记录 bounded summary。

### Provider Usage Availability

不是所有 provider 都稳定提供 usage。尤其是 OpenAI-compatible / Anthropic-compatible 第三方网关、streaming response、代理服务、旧模型接口，可能出现：

- 完全没有 usage；
- 只有 input / output 的部分字段；
- 字段名与 OpenAI / Anthropic 原生 shape 不一致；
- usage 只出现在最终 chunk，但流式库没有透传；
- provider 返回的 total tokens 是否包含 reasoning tokens 不明确。

因此 usage normalize 的 contract 是：

```elixir
@type normalized_usage ::
        Nex.Agent.Turn.ContextWindow.TokenUsage.t()
        | nil

@spec normalize_usage(term(), keyword()) :: normalized_usage()
```

`nil` 是合法降级状态，不是错误。缺 usage 时：

- 不写 fake provider anchor；
- ledger 不更新 `last_successful_anchor`；
- projection 继续使用 estimator-only 预算；
- ControlPlane 标记 `usage_source="estimate"`；
- `runner.llm.call.finished` 仍记录 `usage_available=false`。

usage 部分可用时：

- 已知字段来自 provider；
- 缺失字段由 estimator 补齐；
- `TokenUsage.source` 标记为 `:mixed`；
- ControlPlane 标记 `usage_source="mixed"` 和 `usage_missing_fields`。

只有当 provider usage 字段完整且 provider/model 组合被当前 adapter 认为可信时，才能把它写为 `source: :provider` 并更新 successful anchor。

### Ledger Projection

Session metadata 新增一个 bounded projection，不放完整 prompt、完整 tool result、完整 provider response：

```elixir
%{
  "context_window_v2" => %{
    "version" => 1,
    "provider" => "openai_codex",
    "model" => "gpt-5.5",
    "model_key" => "gpt-5.5-xhigh-fast",
    "history_version" => 42,
    "last_successful_anchor" => %{
      "message_index" => 28,
      "response_id" => "resp_...",
      "usage" => %{
        "input_tokens" => 12345,
        "cached_input_tokens" => 10000,
        "output_tokens" => 800,
        "reasoning_output_tokens" => 3000,
        "total_tokens" => 16145,
        "source" => "provider"
      },
      "recorded_at" => "2026-05-01T..."
    },
    "last_projection" => %{
      "mode" => "token_budget",
      "message_count" => 28,
      "base_tokens_estimate" => 9000,
      "history_tokens_estimate" => 22000,
      "tool_schema_tokens_estimate" => 6000,
      "media_tokens_estimate" => 0,
      "input_budget_tokens" => 233404,
      "usage_source" => "mixed",
      "truncated_tool_outputs" => 1,
      "compaction_items_count" => 1
    },
    "last_incomplete" => %{
      "finish_reason" => "incomplete",
      "reason" => "max_output_tokens",
      "iteration" => 3,
      "usage" => %{},
      "recorded_at" => "2026-05-01T..."
    }
  }
}
```

Ledger 必须 bounded。不能把 raw messages、图片 bytes、tool result 全文、密钥、完整 response body 写入 metadata。

## Request Flow

### 1. Owner run 初始投影

```text
Runner.build_initial_messages
-> ContextWindow.project_request(session, prompt, media, runtime, opts)
-> ContextBuilder.build_messages(projected_history, ...)
-> ContextWindow.prepare_provider_options(projection, opts)
```

`project_request/6` 返回：

```elixir
{:ok,
 %ContextWindow.Projection{
   history: [map()],
   provider_options: keyword(),
   attrs: map(),
   ledger: Ledger.t()
 }}
```

Runner emits `runner.context_window.projected` with `projection.attrs`.

### 2. Tool loop 再投影

每次 tool batch 完成后，下一次 LLM 调用前必须重新投影：

```text
assistant tool_calls + tool outputs added
-> ContextWindow.project_loop_request(session, current_messages, last_response, opts)
-> maybe truncate latest tool outputs
-> maybe attach provider compaction items
-> next LLM call
```

这解决当前只在首轮选择 history 的问题。尤其 OCR、网页抓取、日志读取这类 tool result 会在 loop 中突然放大上下文。

### 3. Response 记账

LLM 返回后，Runner 调用：

```elixir
ContextWindow.record_response(session, response, projection, opts)
```

行为：

- `finish_reason in ["stop", "tool_calls"]`：如果有 provider usage，更新 successful anchor。
- `finish_reason == "incomplete"`：记录 incomplete evidence，不持久化空 assistant 消息，交给 `ContextWindow.Failure` 决定 retry / fail。
- `finish_reason == "error"` 或 transport error：记录 failure summary，不更新 successful anchor。
- response 包含 native compaction items：更新 compaction projection，但不把它当成 session history 的替代真相源。

## Incomplete Policy

`finish_reason="incomplete"` 必须不再进入 `handle_response/9` 的成功路径。

第一版策略：

1. 如果 `incomplete_details.reason == "max_output_tokens"`，且本轮没有可见 content / tool calls：
   - 降低 reasoning effort 或增加 output reserve 二选一不应由代码擅自改模型配置；
   - Runner 返回可操作错误，提示当前模型生成预算耗尽；
   - ControlPlane 记录 `runner.llm.call.incomplete`。
2. 如果 usage 显示 input 接近 context window：
   - 尝试一次更激进投影：保留当前 user turn、最近完整 tool pair、runtime system prompt，丢弃更早 history；
   - retry 最多一次，并记录 `retry_reason="context_pressure"`;
   - retry 仍 incomplete 则失败。
3. 如果 provider 没给 `incomplete_details`：
   - 记录 `reason="unknown"`;
   - 不把空响应当成功；
   - 用户可见错误应说明“模型返回 incomplete 且未提供原因”。

ControlPlane attrs 必须包含：

```text
finish_reason
incomplete_reason
usage_summary
projection_summary
retry_count
provider
model
model_key
iteration
```

## Estimator Strategy

### 第一阶段 estimator

不引入重量 tokenizer，先替换 `chars / 4` 为 byte-aware heuristic：

- ASCII / common code：约 `bytes / 4`
- CJK text：约 `chars`
- JSON / tool schema：`bytes / 3`
- base64 / data URL：按 bytes 上限直接折算并强制截断
- image/media attachment：按 provider projection 估算；若只传 local path 或 metadata，成本接近 text metadata；若转 data URL，必须按实际 data URL bytes 估算

估算结果需要携带 breakdown：

```elixir
%{
  total: 12345,
  text: 8000,
  tool_outputs: 2500,
  tool_schemas: 1200,
  media: 600,
  runtime_prompt: 45,
  method: "byte_heuristic_v1"
}
```

### 第二阶段 tokenizer

后续可加入 provider/model tokenizer adapter：

```text
ContextWindow.Estimator.Tokenizer
```

但 tokenizer 不应改变外部 contract。不可用时继续 fallback heuristic，并在 projection attrs 中标记 `estimator="heuristic"`.

## Tool Output Policy

工具结果是最容易在 loop 中把上下文打爆的来源。V2 需要把 tool output 截断放进 ContextWindow，而不是散在各 tool 内：

- 每个 tool result 存 session 时可以保留完整摘要或 bounded body；
- 发给模型时由 `Projector` 决定可见 body；
- 对 `bash`、网页抓取、OCR、下载列表、日志读取等高风险输出，默认有 token cap；
- 被截断的 tool output 必须包含尾部说明和可恢复线索，例如文件路径、总行数、截断方式；
- 工具本身仍可做 domain-specific summary，但不是 context safety 的唯一防线。

## Native Compaction

继续保留 2026-04-27 finding 的 contract：

- `ContextWindow` 决定是否使用 native compaction；
- provider adapter 只翻译 payload；
- native compaction item 是 opaque provider item，只能存在 session metadata 的 bounded projection；
- 本地 history 仍是长期对话真相源。

V2 增加两个约束：

- provider usage anchor 和 native compaction projection 必须绑定同一个 model/provider；切换 `/model` 后不能复用旧模型 compaction items。
- compaction projection 失效时，必须回退到 local recent history，而不是把旧 compaction item 继续塞给新模型。

## Observability

新增或扩展 ControlPlane observations：

```text
runner.context_window.projected
runner.context_window.ledger.updated
runner.context_window.tool_output.truncated
runner.llm.call.incomplete
runner.llm.call.retry_planned
```

`runner.llm.call.finished` 必须携带 bounded usage summary：

```text
finish_reason
usage.input_tokens
usage.output_tokens
usage.reasoning_output_tokens
usage.total_tokens
incomplete_reason
context_projection_id
```

禁止写入：

- full prompt
- full messages
- full tool result
- raw image bytes / base64
- secrets / access tokens

## Config Contract

Model runtime 继续读取这些字段：

```text
context_window
model_context_window
context_tokens
max_context_tokens
context_limit
auto_compact_token_limit
model_auto_compact_token_limit
context_strategy
```

V2 可新增：

```json
{
  "context_effective_percent": 95,
  "context_safety_margin_tokens": 4096,
  "context_output_reserve_tokens": 4096,
  "tool_output_token_limit": 12000,
  "context_accounting": "server_anchor_then_estimate"
}
```

这些字段仍属于 model config / provider metadata 解析路径，不能在 Runner 或 provider adapter 中裸读 config。

## Migration Plan

### Stage 1: Response Evidence

- Normalize provider usage into `ContextWindow.TokenUsage`.
- Preserve `incomplete_details` / response status in `ReqLLM` response metadata.
- Make Runner treat `finish_reason="incomplete"` as non-success.
- Add focused tests for incomplete empty response not producing assistant message.

### Stage 2: Ledger

- Add `ContextWindow.Ledger` and bounded session metadata projection.
- Update ledger after each successful response.
- Emit `runner.context_window.ledger.updated`.
- Keep existing history selection behavior except usage source reporting.

### Stage 3: Estimator

- Replace `chars / 4` with byte-aware estimator and breakdown attrs.
- Add unit tests for CJK text, JSON/tool output, media data URL, and tool schema estimates.
- Keep estimator module swappable for future tokenizer.

### Stage 4: Loop Projection

- Re-project before every LLM loop iteration, not only initial prompt.
- Add tool output truncation at projection boundary.
- Add tests where a tool output exceeds budget and the next request receives a bounded output.

### Stage 5: Native Compaction And Model Switch Safety

- Bind native compaction projection to provider/model/model_key.
- Drop stale compaction items after `/model` switch.
- Add tests for model switch not reusing old compaction projection.

## Open Questions

1. OpenAI Codex backend exposes which exact usage fields for `gpt-5.5` under Responses stream, and whether `reasoning_output_tokens` is included in `total_tokens`.
2. Should `xhigh-fast` session override default output reserve be larger than 4096 because high reasoning can exhaust output budget before visible text?
3. Should OCR/download tools return file manifests by default and require explicit file reads for large extracted text, instead of returning all text inline?
4. Do follow-up LLM turns need their own smaller context ledger, or should they share owner session ledger with a `turn_kind` dimension?

## Review Fail Conditions

- Runner continues to treat `finish_reason="incomplete"` as `ok`.
- Context trimming remains a one-time pre-run step and ignores tool-loop growth.
- Provider adapters start owning independent history trimming or compaction state.
- Session metadata stores raw prompts, raw tool outputs, image bytes, base64 payloads, or secrets.
- `/model` switch can reuse old provider/model compaction items.
- ControlPlane cannot answer why a response was incomplete, what usage was reported, and what projection was sent.
