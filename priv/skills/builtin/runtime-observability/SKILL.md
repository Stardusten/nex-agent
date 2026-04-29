---
name: runtime-observability
description: Use when answering or debugging runtime status, failures, stuck tasks, logs, incidents, ControlPlane observations, budgets, gauges, owner runs, follow-up state, or background task evidence.
user-invocable: false
---

# Runtime Observability

Use this skill when the user asks whether something failed, is stuck, is still running, what the backend saw, what logs show, or what happened in a run/session/tool/HTTP call.

## Truth Source

ControlPlane observations are the machine truth source. Human text logs are projections.

Prefer:

```text
observe summary
observe incident
observe query
/status for the current chat quick view
```

Do not infer "nothing failed" from silence, elapsed time, process age, or an owner snapshot alone.

## Default Triage

1. Identify workspace, session_key, run_id, channel/chat, tool, or trace dimension if available.
2. Use `observe summary` for current gauges, budgets, recent warnings, and active owner runs.
3. Use `observe incident` with `run_id` or a focused query for current-run failures.
4. Use `observe query` when you need exact observations by tag, session, tool, level, or trace.
5. Answer with concrete evidence and timestamps/tags when useful.

Useful filters:

```text
tag
tag_prefix
kind
level
run_id
session_key
channel
chat_id
tool
tool_call_id
tool_name
trace_id
query
since
limit
```

## Run Control

- `run.owner.current` tracks active owner runs.
- An empty owner gauge means no active owner run is currently projected; it does not prove a completed subagent failed.
- `spawn_task` creates a task-scoped child run with session key `subagent:<task_id>`.
- `/status` is deterministic and should show current owner state plus recent warning/error evidence for the current chat.
- Follow-up turns are not owner runs and should use read-only evidence unless the user explicitly asks to interrupt.

## Budget And Evolution Evidence

- Budget controls review/candidate signal spending.
- Budget never authorizes automatic deploy, code repair, memory writes, skill writes, or SOUL changes.
- Evolution candidates and lifecycle should be read from ControlPlane-derived views, not invented from prompt memory.

## Answering

Lead with the observed state, then cite the evidence source briefly.

Avoid:

- claiming a task is safe, done, or failed without observation evidence
- treating text logs as more authoritative than ControlPlane
- suggesting deploy/restart unless a tool/result explicitly supports it
