# 2026-04-25 Local Tool Backend Selection

## Summary

For `web_search`, `image_generation`, and future tool-backed external capabilities, `nex-agent` should expose one stable local tool contract to the model and keep backend choice entirely behind that local tool boundary.

This repository should not reintroduce a parallel `provider_native` tool lane for these capabilities.

## Why This Was Needed

The previous direction mixed two different concerns:

- model-visible tool contract
- backend implementation choice

That produced extra abstractions such as capability resolver, provider-native strategy, builtin tool passthrough, and registry/request-path branching.

Those abstractions were not buying product value for the current requirements because the desired product model is simpler:

- the model always sees a normal local function tool
- the runtime always executes a normal local tool
- the local tool may internally call different backends such as DuckDuckGo or Codex

The earlier architecture made the code look like it supported two execution lanes while product policy only allowed one of them.

## Decided Architecture

Freeze the following model for these tools:

1. Model-visible identity is always the local tool name.
   Examples:
   - `web_search`
   - `image_generation`

2. `Runner`, `ReqLLM`, and `Tool.Registry` only deal with ordinary local function tools for this class of capability.

3. Backend choice lives inside the tool implementation, driven by tool config.

4. Backend modules are implementation details.
   Examples:
   - DuckDuckGo search backend
   - Codex search backend
   - Codex image backend
   - future `nanobanana` image backend

5. For the current simplified version, backend choice is explicit and fixed by config rather than dynamically resolved.

## Frozen Boundaries

These points are intentionally frozen and should be treated as review checks.

### 1. No provider-native lane for these tools

Do not model `web_search` or `image_generation` as:

- provider-native tool definitions visible to the model
- builtin tool shapes passed through `ReqLLM`
- registry execution branches like `:provider_native`
- capability strategy values such as `provider_native`

Reason:

- this creates a second orchestration lane
- it spreads policy across Registry, ReqLLM, Runner, and provider policy
- it violates the intended product contract

### 2. One stable local tool contract

For this class of capability, the model must only see the local function-tool contract.

It must not see:

- `codex_web_search`
- `openai_web_search`
- native/builtin aliases
- one tool name on one provider and a different tool name on another

### 3. Backend selection is configuration, not model contract

Backend choice is allowed to change implementation behavior, but it must not change the model-visible tool name or schema family.

### 4. `web_search` and `image_generation` stay on the same abstraction level

Do not let one of them use:

- local tool + backend selection

while the other uses:

- provider-native exposure
- special Runner/ReqLLM handling
- a separate orchestration concept

Future backends such as `nanobanana` should extend the same local-tool-backend pattern.

## Config Shape

For these tools, prefer provider-style config:

```json
{
  "tools": {
    "web_search": {
      "provider": "duckduckgo",
      "providers": {
        "duckduckgo": {},
        "codex": {
          "mode": "live",
          "allowed_domains": [],
          "user_location": null
        }
      }
    }
  }
}
```

Interpretation:

- `provider` is the selected backend
- `providers` is the backend config table

For the current mainline:

- backend choice should be explicit
- do not add dynamic resolver complexity unless product requirements change

## What Reviewers Should Reject

Reject changes that:

- reintroduce `provider_native` terminology or control flow for these tools
- make `ReqLLM` understand builtin tool shapes for these capabilities
- make `Tool.Registry` branch on backend/provider-native execution strategy
- split `web_search` and `image_generation` into different architectural patterns
- replace explicit backend selection with hidden auto-routing without a clearly reviewed product requirement

## Follow-On Guidance

If future work needs true provider-native orchestration, it must justify a separate architecture on its own merits and must not silently piggyback on the local tool backend-selection path.

For the current tool family, the intended direction is:

- local tool façade
- backend-specific implementation behind that façade
- no second lane
