# 2026-04-25 Advisor Mode Design Notes

Status: discussion note, not implementation plan.

This note records the current advisor-mode discussion and the related Anthropic / Claude Code design signals. It intentionally keeps competing options, tradeoffs, and open questions instead of turning them into a phase plan.

## Why This Came Up

The new config shape now has model roles:

- `default_model`
- `cheap_model`
- `advisor_model`

That makes it possible to think about a mixed-model execution style:

- a normal or cheaper executor model keeps doing the main work
- a stronger advisor model reviews plans, diagnoses stuck states, or reviews work before completion
- the executor continues after receiving advice

The important product premise is that this should not mean switching models inside the same LLM session. Switching mid-session wastes provider-side cache and muddles the conversation model. The more natural design is multiple sessions or multiple calls:

- one session writes a plan, another model/session reviews it
- one executor session works, then asks an advisor session for guidance
- a forked session starts from a parent session point and explores a branch

This aligns with the way Claude Code appears to separate subagents, sessions, and forks.

## External Signals

### Anthropic Advisor Strategy

Source: [The Advisor Strategy](https://claude.com/blog/the-advisor-strategy)

The article describes a fast executor model periodically consulting a stronger advisor model. The advisor does not replace the executor. It gives recommendations, tradeoffs, warnings, and next steps.

Useful trigger classes from that article:

- before implementation, for architecture and plan review
- when stuck, for diagnosis and alternate approaches
- after implementation, for final review before declaring success

This maps well to NexAgent because owner runs already have clear lifecycle points: planning, tool execution, stuck/failure observations, and final response.

### Claude Code Subagents

Source: [Claude Code subagents](https://code.claude.com/docs/en/sub-agents)

Claude Code subagents are described as isolated agents with their own context window, custom system prompt, tool permissions, and optionally model choice. They can be selected automatically or invoked explicitly.

The useful distinction for NexAgent:

- subagent is a task delegation mechanism
- advisor is a consultation mechanism
- they can share infrastructure, but they are not identical product concepts

### Claude Code SDK Subagents

Source: [Claude Code SDK subagents](https://code.claude.com/docs/en/agent-sdk/subagents)

SDK subagents are defined with fields such as name, description, prompt, tools, and model. They become callable as task-like capabilities.

This suggests a future NexAgent direction where subagents are not just a generic background task runner, but named profiles:

- `code_reviewer`
- `planner`
- `debugger`
- `advisor`
- `researcher`

Each profile could have its own prompt, tool surface, and model role.

### Claude Code SDK Sessions And Forking

Source: [Claude Code SDK sessions](https://code.claude.com/docs/en/agent-sdk/sessions)

The SDK exposes session continuation and forking. A caller can resume a specific session id and request a forked session. Conceptually, this means:

- a parent session has a persisted conversation state
- a fork starts from a previous point
- the original session can continue independently

This is the cleanest conceptual match for `/btw`-style side branches or plan review branches, but it is also heavier than a simple advisor call.

### Claude Code Slash Commands

Source: [Claude Code slash commands](https://code.claude.com/docs/en/commands)

The public command list includes commands such as `/compact`, `/clear`, and `/model`. It does not currently document `/btw` in the public page that was checked.

That means `/btw` can be useful as a product/design reference, but NexAgent should not assume a public canonical implementation from the docs alone.

## Current NexAgent Subagent Reality

NexAgent already has a subagent capability, but it is currently closer to a background task runner than a Claude Code style profile system.

Relevant current files:

- `lib/nex/agent/subagent.ex`
- `lib/nex/agent/tool/spawn_task.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/worker_supervisor.ex`

What exists now:

- `Nex.Agent.Capability.Subagent` is a GenServer supervised under `WorkerSupervisor`.
- `spawn_task` is a tool that can create a background subagent task.
- each subagent task creates an independent session key like `subagent:<task_id>`.
- the task runs `Nex.Agent.Turn.Runner.run/3`.
- subagent runs use `tools_filter: :subagent`.
- completion is announced back through the Bus as an inbound message with `_from_subagent` metadata.
- owner run cancellation can cancel related subagent tasks.

What is missing if we compare it with Claude Code style subagents:

- no named subagent profile registry
- no per-profile prompt
- no per-profile model role
- no advisor-specific return path
- no session fork from a parent message index
- no structured result channel back into the parent runner
- no distinction between "background task result for the user" and "internal advice for the executor"

So the current subagent infrastructure is useful, but not yet the whole advisor story.

## Design Axes

The advisor design space has several independent axes. Keeping them separate helps avoid overbuilding the first version.

### Axis 1: Who Triggers Advice

Possible trigger modes:

- deterministic lifecycle hooks
- model-callable advisor tool
- explicit user command
- background policy based on ControlPlane evidence

Deterministic hooks are easier to reason about:

- before plan is committed
- after repeated tool failure
- when a run exceeds time or iteration thresholds
- before final answer

Model-callable advisor tools are more flexible:

- the executor decides when it needs help
- this resembles the Advisor Strategy article
- it needs loop and budget controls

Explicit command is useful for user control:

- `/advisor review this plan`
- `/advisor why are you stuck`
- `/advisor ask bigger model before continuing`

ControlPlane-triggered advice is attractive later:

- repeated `tool.call.failed`
- `llm.call.failed`
- current run shows same failure pattern as past incidents
- budget mode allows deeper reflection

### Axis 2: What Context Advisor Sees

Possible context packages:

- concise summary generated by executor
- recent transcript window
- structured run snapshot
- current plan
- recent tool calls and errors
- selected files or diffs
- full forked session history

The smallest useful package for advisor likely includes:

- user request
- current plan or attempted approach
- current run state
- recent errors and tool outputs
- executor question
- workspace / project context

Full session fork gives more fidelity, but it brings persistence and branch semantics with it.

### Axis 3: How Advice Returns

Possible return paths:

- direct return value to parent Runner
- tool result in executor transcript
- ControlPlane observation only
- inbound message visible to the user
- side session transcript linked to parent

For advisor mode, the likely best early shape is:

- record the advisor call in ControlPlane
- return structured advice to the parent Runner
- inject a concise advisor note into the executor's continuing context

It should probably not look like a normal assistant message from another personality. It is internal guidance for the executor unless the user explicitly asks to see it.

### Axis 4: Whether Advisor Can Use Tools

Possible tool access levels:

- no tools
- read-only tools
- subagent tool surface
- custom advisor surface
- full owner tools

Early advisor probably does not need tools. The parent can provide the relevant context package.

If advisor later needs to inspect files or logs, a read-only advisor surface is safer than full subagent or owner tools.

### Axis 5: Whether Advisor Is A Subagent

Advisor can be implemented as:

- simple service call
- internal tool
- specialized subagent profile
- forked session

These are not mutually exclusive. A future architecture could support all of them:

- `Advisor.Service.ask/2` as the core
- `ask_advisor` tool as one caller
- advisor subagent profile as another caller
- session fork as the heavy branch-capable primitive

## Option A: Inline Advisor Call

The parent Runner calls advisor model directly through a dedicated advisor service.

Shape:

```elixir
Advisor.ask(request, runtime_snapshot)
```

The request contains:

- trigger
- parent session key
- run id
- workspace
- user request
- current plan
- recent transcript window
- recent tool failures or observations
- executor question

The response contains:

- advice
- risks
- next actions
- confidence
- raw model metadata

Pros:

- smallest implementation
- does not require session fork
- does not require subagent profile registry
- naturally uses `advisor_model_runtime`
- keeps executor model/session stable

Cons:

- advisor only sees the packaged context
- not independently tool-using
- needs careful prompt shaping to avoid vague advice

This seems like the most practical MVP if the goal is advisor mode specifically.

## Option B: Advisor Tool

Expose an internal `ask_advisor` tool to the executor. The executor can call it when it wants help.

Pros:

- close to the Advisor Strategy pattern
- executor can decide when help is needed
- tool result naturally enters the executor's reasoning context
- easy to make manual and automatic behavior share one path

Cons:

- can loop or overuse the advisor
- cost control needs to be explicit
- tool result may clutter transcript unless handled carefully
- the executor prompt must teach when to ask and when not to ask

This could be a good second step after the service exists.

## Option C: Advisor As Specialized Subagent

Create an advisor subagent profile using the existing subagent execution machinery, but with a dedicated prompt/model/tool surface.

Pros:

- builds toward Claude Code style named subagents
- can later support read-only inspection tools
- consistent with existing `spawn_task` mental model
- easier to reuse for code review, plan review, debugging

Cons:

- current `Subagent` is task-result oriented, not consultation-result oriented
- current completion path publishes inbound messages, which is not ideal for internal advice
- no profile registry yet
- no per-profile model role yet

This becomes attractive once subagent profiles are designed.

## Option D: Session Fork Advisor

Introduce a generic session fork primitive. Advisor starts from a parent session point, runs as a branch with advisor model, then returns findings to the parent.

Pros:

- closest to Claude SDK `forkSession` concept
- useful beyond advisor
- can power `/btw`, plan review branches, parallel exploration, and experiments
- preserves more historical context than summary-only advisor calls

Cons:

- touches session/event-log truth source
- needs parent/child branch metadata
- needs message index or run id anchoring
- needs memory-write rules for forked sessions
- needs cancellation and observability semantics
- may be too heavy for first advisor mode

This seems like a separate design topic rather than the first advisor implementation.

## Option E: Multi NexAgent Collaboration Over IM

Run multiple NexAgent instances, each with one model or role, and let them communicate through IM.

Pros:

- models/processes are genuinely isolated
- fits broader multi-agent collaboration
- no need to force everything into one NexAgent runtime

Cons:

- belongs more to product-level orchestration
- requires identity, routing, channel, and conversation protocol decisions
- not the right place for a simple built-in advisor mode

This remains an important larger direction, but not the local advisor-mode MVP.

## Current Leaning

Current leaning from the discussion:

1. Do not model advisor as switching model in the same session.
2. Treat advisor as a separate call or separate session.
3. Start with a narrow built-in advisor mode rather than fully generic multi-agent orchestration.
4. Reuse the new config model roles, especially `advisor_model`.
5. Reuse ControlPlane for durable advisor-call evidence.
6. Avoid making advisor output look like a normal user-visible subagent message.
7. Keep generic session fork as a later, separate design topic.
8. Improve subagent separately toward named profiles, model roles, and structured result return.

## Possible Request / Response Sketch

This is only a discussion sketch, not a settled API.

```elixir
%Advisor.Request{
  trigger: :before_plan | :stuck | :pre_finish_review | :manual | :tool_call,
  parent_session_key: session_key,
  parent_run_id: run_id,
  workspace: workspace,
  user_request: text,
  executor_question: question,
  current_plan: plan,
  transcript_window: messages,
  observations: observations,
  artifacts: %{
    recent_tool_calls: tool_calls,
    recent_errors: errors,
    candidate_diff: diff
  }
}
```

```elixir
%Advisor.Response{
  advice: text,
  risks: risks,
  next_actions: actions,
  confidence: confidence,
  model_runtime: runtime,
  usage: usage,
  raw: raw
}
```

The response could be recorded as ControlPlane observations such as:

- `advisor.call.started`
- `advisor.call.finished`
- `advisor.call.failed`

The parent Runner could receive a compact note such as:

```text
Advisor note:
- ...
```

The exact injection method is still open.

## Subagent Enhancement Discussion Points

The existing subagent system can evolve independently of advisor mode. Topics to discuss next:

### Named Profiles

Instead of one generic background subagent prompt, support named profiles:

```elixir
%Subagent.Profile{
  name: "code_reviewer",
  description: "Review code changes for correctness and missing tests.",
  prompt: "...",
  model_role: :advisor,
  tools_filter: :subagent
}
```

Open questions:

- should profiles live in config, files, or code?
- should they be user-editable like skills?
- should they be hot-reloaded by Runtime?
- should descriptions be visible to the owner model for auto-delegation?

### Model Role Selection

Subagents currently inherit the parent provider/model through tool context. A profile system could choose:

- inherit parent model
- use `cheap_model`
- use `default_model`
- use `advisor_model`
- use explicit model key

Open questions:

- should ordinary background subagents default to cheap model?
- should review/advisor profiles default to advisor model?
- should user-created subagents be allowed to pick any model key?

### Result Return Modes

Current subagent completion publishes an inbound message. Future profiles may need different return modes:

- user-visible completion message
- internal parent-run result
- ControlPlane observation only
- artifact written to workspace
- branch transcript linked to parent

Advisor likely wants internal parent-run result, not inbound message.

### Tool Surface

Current `:subagent` surface allows code inspection and patch tools but not outward communication or recursive spawn.

Future advisor/reviewer profiles may want:

- no tools
- read-only tools
- code review tools
- patch tools
- custom profile-specific allowlist

Open question:

- should tool permissions remain surface-based, or become profile-specific?

### Session Model

Current subagent creates a new blank session with only the task prompt.

Possible future modes:

- blank task session
- summary-seeded session
- transcript-window-seeded session
- full fork from parent session point

The last one is session fork and should probably be designed as its own primitive.

### Cancellation And Ownership

Current subagent tasks already track `owner_run_id` and `session_key`, which is useful.

Open questions:

- should advisor calls be cancelled with the parent run?
- should subagent profile runs be visible in `/status`?
- should `/stop` cancel all child advisor/subagent work by default?

### Observability

Subagents currently have some performance recording through `SubAgent.Review`, and the system has ControlPlane for runtime observations.

Open questions:

- should all subagent lifecycle events move to ControlPlane?
- should advisor use the same event family or a separate `advisor.*` family?
- should profile performance feed future self-improvement?

## Things To Avoid For Now

This is not a final decision list, but current cautions from the discussion:

- do not make advisor a hidden model switch inside the same session
- do not force full session fork just to get first advisor value
- do not make advisor automatically user-visible unless the command asks for it
- do not let advisor write memory, patches, messages, or deployment state in the first shape
- do not treat existing `spawn_task` as already equivalent to Claude Code subagents
- do not bury model role choice in tool code instead of going through config/runtime

## Discussion State

The current design conversation is roughly here:

- advisor mode should likely begin as a narrow built-in consultation mechanism
- current subagent infrastructure is useful but not sufficient for advisor profiles
- session fork is important but belongs to a broader conversation about `/btw`, branches, event logs, and memory boundaries
- next useful discussion is how to enhance subagent from generic background task runner into named, model-aware, profile-driven agents

