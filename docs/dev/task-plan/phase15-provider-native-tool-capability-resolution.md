# Phase 15 Tool Backend Selection (Aborted)

## 当前状态

ABORTED on 2026-04-25.

This file previously described a provider-native / capability-resolved tool exposure plan. That direction is no longer active and must not be implemented.

The active decision is [2026-04-25 Local Tool Backend Selection](../findings/2026-04-25-local-tool-backend-selection.md):

- the model sees only stable local function tools
- `Runner`, `ReqLLM`, and `Tool.Registry` do not branch on backend selection
- backend choice stays inside each local tool implementation
- Codex search/image backends are implementation details behind `web_search` / `image_generation`

## 完成后必须达到的结果

No implementation work should be taken from the aborted original Phase 15 plan.

The repository must keep the local tool backend-selection contract:

```elixir
%{
  "provider" => "duckduckgo" | "codex",
  "providers" => %{
    "duckduckgo" => %{},
    "codex" => %{}
  }
}
```

## 开工前必须先看的代码路径

- `docs/dev/findings/2026-04-25-local-tool-backend-selection.md`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/tool/web_search.ex`
- `lib/nex/agent/tool/image_generation.ex`
- `lib/nex/agent/config.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/llm/req_llm.ex`

## 固定边界 / 已冻结的数据结构与 contract

1. The model-visible tool contract is always the local tool name.
2. `web_search` and `image_generation` stay ordinary local function tools.
3. Backend selection is explicit tool config, not a model-visible contract.
4. `Tool.Registry`, `Runner`, and `ReqLLM` must not add a second tool orchestration lane for these capabilities.

## 执行顺序 / stage 依赖

This phase has no active stages. Future work must open a new task plan that starts from the local-tool backend contract.

## Stage 0

### 前置检查

Confirm the current finding above is still the active architecture decision.

### 这一步改哪里

None.

### 这一步要做

None. This phase is historical only.

### 实施注意事项

Do not resurrect the aborted design from git history.

### 本 stage 验收

The current code and tests keep `web_search` / `image_generation` as local function tools.

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/config_test.exs test/nex/agent/tool_alignment_test.exs test/nex/agent/llm/providers/openai_codex_test.exs
```

## Review Fail 条件

- A model-facing Codex search/image tool bypasses `Tool.Registry`.
- `Runner`, `ReqLLM`, or `Tool.Registry` branches on backend selection for these tools.
- Backend choice changes the model-visible tool name or schema family.
- Tests or docs describe backend selection as a second model-visible tool lane.
