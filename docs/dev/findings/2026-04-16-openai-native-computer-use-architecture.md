# 2026-04-16 OpenAI Native Computer Use Architecture

## Summary

`nex-agent` can support OpenAI native computer use, but the current architecture cannot do it cleanly by adding one more tool module.

The current stack is built around one assumption:

- model-visible tools are ordinary function tools
- model outputs tool calls as function calls
- runtime executes those calls through `Nex.Agent.Capability.Tool.Registry`
- tool results go back into the transcript as `"role" => "tool"`

OpenAI native computer use breaks that assumption.

It uses the Responses API built-in tool path, where the model emits computer-use items such as `computer_call`, the runtime executes those actions against a real computer/browser environment, and the next model request must send back `computer_call_output` tied to the prior response chain.

So the correct architectural move is:

- do not cram native computer use into the existing function-tool abstraction
- introduce a provider-native built-in tool orchestration layer
- keep ordinary workspace tools and provider-native tools as separate capability classes

This avoids a design that works only for one demo and becomes debt when other OpenAI built-in tools need the same treatment.

## Current Behavior

Current code paths are function-tool-centric:

- [ReqLLM tool encoding](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/llm/req_llm.ex#L212) converts all tools into `ReqLLM.Tool`
- [Runner tool normalization](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/runner.ex#L461) rewrites all model-emitted tool calls to `"type" => "function"`
- [Runner tool execution](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/runner.ex#L820) dispatches calls only through local skill runtime or `Tool.Registry`
- [Session history repair](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/session.ex#L79) only understands assistant-tool message pairing in the current function-call transcript model

This means native computer use is blocked in four places:

1. request tool schema shape
2. response item parsing
3. execution routing
4. response continuation state

## Protocol Facts That Matter

The relevant OpenAI protocol facts are stable enough to freeze at the architecture level:

1. OpenAI native computer use is a Responses API built-in tool, not an ordinary function tool.
2. The model can emit computer-use response items that are not `function_call`.
3. The runtime must execute the requested action against a real environment and send back tool output items on the next request.
4. Continuation is tied to the response chain, so the runtime must preserve provider-native response state such as `previous_response_id`.
5. Safety checks can require explicit acknowledgement and therefore cannot be modeled as a transparent local function call.

Official references:

- https://platform.openai.com/docs/guides/tools-computer-use
- https://platform.openai.com/docs/api-reference/responses/create
- https://developers.openai.com/api/docs/models/computer-use-preview

## Decided Architecture

Introduce a two-lane capability model.

Lane 1:

- workspace/runtime function tools
- current `Nex.Agent.Capability.Tool.Registry` model
- skill-runtime ephemeral tools
- normal `"tool"` transcript entries

Lane 2:

- provider-native built-in tools
- OpenAI Responses API item loop
- native response continuation state
- provider-specific execution adapters

These lanes must meet in `Runner`, but they must not share the same internal representation.

## Frozen Boundary: Do Not Model Native Computer Use As A Registry Tool

This boundary is frozen.

Native computer use must not be represented as:

- `Nex.Agent.Tool.BrowserOpen`
- `Nex.Agent.Tool.BrowserClick`
- synthetic `computer_use` function schema in `Tool.Registry`
- fake `"type" => "function"` tool calls with JSON arguments

Reason:

- that loses provider-native semantics such as action stream shape, safety acknowledgements, and response chaining
- that makes OpenAI built-in tools look like local tools when they are not
- that would force more special cases into `Tool.Registry`, `Session`, and `ReqLLM` later

Function-tool browser automation can still exist as a separate capability, but it is not the native computer-use path.

## New Core Abstraction: Response Items

The missing architecture layer is a provider-neutral response-item model.

Introduce a normalized item representation between LLM provider code and `Runner`.

Suggested shape:

```elixir
%Nex.Agent.LLM.Output{
  provider: :openai | :anthropic | atom(),
  model: String.t() | nil,
  output_text: String.t(),
  finish_reason: String.t() | nil,
  usage: map() | nil,
  items: [
    %{
      "id" => String.t() | nil,
      "type" => String.t(),
      "name" => String.t() | nil,
      "call_id" => String.t() | nil,
      "arguments" => map() | String.t() | nil,
      "provider_data" => map()
    }
  ],
  provider_state: %{
    "response_id" => String.t() | nil,
    "previous_response_id" => String.t() | nil
  }
}
```

Rules:

- ordinary function calls become item type `function_call`
- OpenAI native computer use items remain native item types such as `computer_call`
- provider-specific fields not needed by `Runner` stay under `provider_data`
- response continuation data stays under `provider_state`

This boundary lets `Runner` operate on typed items instead of pretending everything is a function call.

## ReqLLM Boundary Changes

`Nex.Agent.Turn.LLM.ReqLLM` should stop exposing only the current simplified map response for the main agent loop.

It should expose a richer normalized output that preserves item types and provider-native state.

Required changes:

1. Request path
   - allow provider-native built-in tools to pass through without conversion into `ReqLLM.Tool`
   - keep local function tools on the existing path
2. Response path
   - parse OpenAI Responses API output items beyond `function_call`
   - preserve provider-native item ids, call ids, and raw provider data
3. Continuation path
   - allow next request construction with provider-native continuation state such as `previous_response_id`

This likely means one of these approaches:

1. extend `req_llm` fork to expose native response items cleanly
2. bypass `req_llm` only for the OpenAI native built-in tool path

The lower-debt choice is:

- extend the `req_llm` fork if the maintainers are already comfortable carrying provider-specific patches there
- otherwise add a narrow OpenAI native adapter module inside `nex-agent` and keep the bypass isolated

What should not happen:

- leaking raw OpenAI JSON parsing into `Runner`
- bolting more special-case branches into `ReqLLM.chat/2` return shape without introducing a stable internal struct

## Runner Must Become Item-Oriented

This boundary is frozen.

`Runner` must orchestrate model output items, not only function tool calls.

Target loop:

1. call LLM
2. receive normalized output items
3. partition items by execution lane
4. append assistant-visible transcript state
5. execute actionable items
6. append execution outputs in the correct lane-specific format
7. continue the loop using preserved provider-native continuation state when required

Concretely:

- function calls still route to `Tool.Registry`
- native computer-use items route to a new executor adapter
- text-only outputs can still finalize immediately

This removes the current bad assumption in [Runner normalization](/Users/krisxin/Desktop/nex-agent/lib/nex/agent/runner.ex#L461).

## New Module: Provider-Native Tool Orchestrator

Add a dedicated orchestrator layer instead of burying logic in `Runner`.

Suggested modules:

- `Nex.Agent.LLM.Output`
- `Nex.Agent.NativeTool.Call`
- `Nex.Agent.NativeTool.Result`
- `Nex.Agent.NativeTool.Orchestrator`
- `Nex.Agent.NativeTool.OpenAI.ComputerUse`

Responsibilities:

- `LLM.Output`
  - normalized model response
- `NativeTool.Call`
  - normalized actionable native item
- `NativeTool.Result`
  - normalized runtime execution result ready to feed back to provider
- `NativeTool.Orchestrator`
  - dispatch native items to provider-specific adapters
- `NativeTool.OpenAI.ComputerUse`
  - translate `computer_call` items into environment actions and translate execution output back into Responses API input items

This keeps provider-specific logic out of generic workspace tool code.

## Computer Session Must Be First-Class Runtime State

Native computer use requires explicit durable session state.

Do not keep computer/browser state only in:

- prompt text
- ad-hoc process dictionary values
- one-off tool outputs embedded in chat history

Add a first-class computer session state model keyed by agent session.

Suggested persisted shape under `Session.metadata` or adjacent runtime store:

```elixir
%{
  "computer_use" => %{
    "provider" => "openai",
    "response_id" => "...",
    "previous_response_id" => "...",
    "environment" => %{
      "kind" => "browser",
      "session_id" => "...",
      "driver" => "agent_browser"
    },
    "last_call_id" => "...",
    "last_snapshot_ref" => "...",
    "last_screenshot_path" => "...",
    "status" => "active"
  }
}
```

Rules:

- provider-native continuation state belongs here
- runtime environment identity belongs here
- ephemeral DOM details do not need durable persistence unless needed for recovery
- this state must survive multi-turn native computer-use tasks

## Execution Environment Boundary

The executor that actually drives the browser/computer must be abstracted from the OpenAI protocol adapter.

Freeze this split:

1. protocol adapter
   - understands OpenAI `computer_call` and `computer_call_output`
2. environment driver
   - knows how to click, type, scroll, capture screenshot, and manage browser lifecycle

Suggested environment behaviour:

```elixir
defmodule Nex.Agent.ComputerUse.Driver do
  @callback ensure_session(map()) :: {:ok, map()} | {:error, term()}
  @callback execute_action(map(), map()) :: {:ok, map()} | {:error, term()}
  @callback close_session(map()) :: :ok | {:error, term()}
end
```

Suggested first concrete driver:

- `Nex.Agent.ComputerUse.Driver.AgentBrowser`

Reason:

- the OpenAI protocol may change independently from the browser tool
- future desktop/native drivers should not require reworking provider-native orchestration

## Safety Checks Are Not Ordinary Tool Errors

Safety checks must be modeled as explicit runtime states.

Do not convert them into:

- generic `"Error: blocked"`
- fake tool failure strings
- invisible retries

Instead, native execution should be able to return a suspended state such as:

```elixir
{:requires_ack,
 %{
   "call_id" => "...",
   "reason" => "...",
   "pending_safety_checks" => [...]
 }}
```

Then the outer runtime can decide how to:

- notify the user
- ask for approval
- record acknowledgement
- resume the native response chain

This is important because human-in-the-loop control is part of the actual product contract, not just an implementation detail.

## Transcript Model Changes

The current session transcript is message-based and optimized for:

- user
- assistant
- tool

Native built-in tools need more structure, but the repo does not need a full transcript rewrite immediately.

Low-debt compromise:

1. keep the existing `Session.messages` list for backward compatibility
2. add explicit metadata fields for native items and provider state
3. store normalized native execution events in request traces first
4. only rewrite persistent transcript storage if message-only persistence proves insufficient

For phase 1 native support:

- assistant text still persists as normal assistant messages
- function tool calls still persist as current assistant/tool message pairs
- native computer-use events persist in session metadata plus request trace
- do not fake them as normal `"role" => "tool"` messages

This prevents polluting long-term transcript assumptions with fake tool messages.

## Runtime Snapshot Integration

Computer-use capability must be inside the runtime snapshot contract once implemented.

The runtime snapshot should eventually include a capability section such as:

```elixir
%{
  native_tools: %{
    openai: %{
      computer_use: %{
        enabled: true,
        driver: :agent_browser,
        model_allowlist: ["computer-use-preview", "gpt-5.4"]
      }
    }
  }
}
```

Reason:

- capability visibility must match the same runtime version discipline as prompt and tools
- users should not hit a state where prompt says native computer use is available but runtime config has not enabled the driver

## Recommended Delivery Order

### Phase A

Freeze internal boundaries without user-visible support:

- add normalized `LLM.Output`
- stop assuming all tool-like items are function calls
- preserve provider-native response ids and raw item types in traces

### Phase B

Add OpenAI native built-in orchestration shell:

- native item dispatcher in `Runner`
- `NativeTool.Orchestrator`
- placeholder adapter for OpenAI computer use

No real browser execution yet.

### Phase C

Add computer session manager and browser driver:

- session state model
- `AgentBrowser` driver
- action execution mapping
- screenshot and state capture pipeline

### Phase D

Add safety and resume contract:

- suspend/resume on pending safety checks
- explicit user acknowledgement path
- request trace visibility

### Phase E

Expose capability to model selection/runtime config:

- provider capability checks
- runtime snapshot integration
- prompt/runtime guidance updates

## Explicit Non-Goals

These should stay out of the first native-computer-use architecture pass:

- full generalization for every future provider-native tool family
- rewriting all session persistence into a new event store immediately
- supporting desktop-wide OS control before browser-focused execution is stable
- inventing a cross-provider “universal computer use protocol”

## Review Fail Conditions

The design should be rejected if implementation takes any of these paths:

1. native computer use is exposed as a fake `Tool.Registry` function
2. `Runner` continues to coerce all tool-like output into `"type" => "function"`
3. provider-native continuation state is stored only in prompt text
4. safety checks are flattened into generic tool error strings
5. browser driver logic is mixed directly into OpenAI response parsing
6. OpenAI-specific raw JSON handling leaks into unrelated providers or generic tool registry code
