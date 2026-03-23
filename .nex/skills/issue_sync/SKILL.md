---
name: issue_sync
description: Update the GitHub issue with concise execution status, blockers, or PR handoff details.
user-invocable: true
requires:
  bins:
    - gh
---

# Issue Sync

Use this skill when the repository worker needs to write a concise status update back to the GitHub issue.

## Workflow

1. Gather the current state: in progress, blocked, or review ready.
2. Write a short issue comment with:
   - what changed
   - what verification ran
   - the PR URL or blocker
3. If the repository uses workflow labels, keep the comment consistent with the current lifecycle label.

## Rules

- Keep issue comments brief and factual.
- If blocked, lead with the blocker and the missing information.
- If review ready, include the PR URL and exact verification summary.
