---
name: lark-feishu-ops
description: Use when working with Feishu/Lark chat messaging, native message payloads, media sends, lark-cli business operations, Feishu Docs/Sheets/Base/Calendar/Tasks/Drive/search, or Feishu-specific troubleshooting.
user-invocable: false
---

# Lark And Feishu Ops

Use this skill for Feishu/Lark-specific operations beyond ordinary plain text replies.

## Chat Messages

For ordinary assistant replies in Feishu, normal assistant text is preferred. Channel rendering happens after generation.

When using the `message` tool for `channel="feishu"`:

- plain `content` is usually enough
- use native `msg_type` and `content_json` only when intentionally sending a Feishu-specific payload
- if sending a local PNG/JPEG file, use `local_image_path`
- do not guess `image_key`, `file_key`, or other platform keys

## Business Operations

Lark/Feishu business operations such as Docs, Sheets, Base, Calendar, Tasks, Drive, or search are not built-in NexAgent tools.

Use external `lark-cli` through `bash` when available.

If `lark-cli` is missing:

- surface the shell error
- give a concise installation/configuration hint
- do not try old `feishu_*` tool names
- do not invent built-in tools that are not present in the current tool list

## Boundaries

- Channel protocol details belong in channel modules or a dedicated deterministic tool, not generic runner logic.
- Do not leak Feishu/Lark protocol-specific payload logic into domain-neutral Workbench, memory, or runtime code.
- Avoid printing secrets, tokens, app secrets, tenant access tokens, or raw config values.
