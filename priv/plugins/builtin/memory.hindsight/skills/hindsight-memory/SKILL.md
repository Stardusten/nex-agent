---
name: hindsight-memory
description: Use when a turn needs long-term memory, cross-session continuity, durable user/project context, or a Hindsight mental model.
user-invocable: false
---

# Hindsight Memory

Hindsight is derived long-term memory. It does not replace NexAgent's local
session history, workspace files, channel catch-up, or ControlPlane evidence.

Use Hindsight for:

- stable facts the user confirmed or repeatedly relies on
- durable preferences, decisions, project conventions, and reusable experience
- cross-session recall when the current context window is insufficient
- mental models that summarize long-running patterns

Use local session history, files, or ControlPlane instead when the user needs
exact wording, timestamps, raw evidence, auditability, or recovery after a
gateway/channel sync issue.

## Recall

Before answering questions about long-term context, prior preferences,
recurring patterns, or "what do you remember", consider `hindsight__recall`.

Treat recall as evidence retrieval. Cite or summarize it cautiously, and do not
pretend Hindsight is the raw source of truth when the answer needs exact
provenance.

## Retain

Save only information that is worth durable memory:

- confirmed user preferences or stable expectations
- long-term project facts, architectural decisions, and workflow conventions
- reusable lessons from failures or repeated work
- explicit user corrections that should shape future behavior

Do not save:

- secrets, credentials, tokens, or private config values
- temporary command output, one-off scratch work, or low-value chatter
- unconfirmed guesses, emotional inference, or speculative security hypotheses
- raw conversation logs when a compact source-backed summary is enough

Every retained memory should include source metadata that lets NexAgent trace
back to the local session, channel, workspace file, or ControlPlane evidence.

## Mental Models

Use `hindsight__mental_model` when the user asks for an established long-term
model, such as "how do I usually make architecture decisions" or "what is my
working style on this project".

Do not use mental models as proof of an exact event. For exact evidence, return
to local session, file, or ControlPlane truth sources.
