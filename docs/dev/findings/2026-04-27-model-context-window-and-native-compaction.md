# Model Context Window And Native Compaction

## Conclusion

Context-window policy is model runtime metadata, not a global runtime setting. Each configured model may carry:

- `context_window`
- `auto_compact_token_limit`
- `context_strategy`

These fields are consumed by `Nex.Agent.Turn.ContextWindow`, which is the single projection boundary for both local history trimming and provider-native compaction.

## Architecture Contract

- `Nex.Agent.Runtime.Config` resolves model context metadata beside `provider`, `id`, and provider request options.
- `Runner` asks `ContextWindow` to select history before building the first LLM request.
- `Runner` asks `ContextWindow` to prepare provider options for that same projected history.
- Provider adapters only translate projected context metadata into provider-specific request payload fields.
- OpenAI Codex native compaction is represented as `context_management: [%{"type" => "compaction", "compact_threshold" => limit}]` plus opaque `compaction` output items carried into the next request.

## Why This Shape

Local token-window trimming and server-side compaction are both answers to one question: what should this model receive as its next input window? Keeping that question in `ContextWindow` prevents a second provider-private memory lane from growing beside session history.

Provider-native compaction remains provider-specific only at the final payload boundary. The runner still sees one contract: model runtime context metadata in, projected history and provider options out.

## Current Limit

Token counting is still heuristic (`chars / 4`) until a tokenizer boundary is introduced. The contract is intentionally narrow enough to swap the estimator later without changing provider adapters or runner orchestration.
