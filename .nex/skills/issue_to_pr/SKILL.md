---
name: issue_to_pr
description: Analyze a GitHub issue, implement the fix, verify it, and hand off to PR creation.
user-invocable: true
requires:
  bins:
    - git
    - gh
---

# Issue To PR

Use this skill when a GitHub issue has already been selected for execution and the goal is to move it from investigation to a ready pull request.

## Workflow

1. Read the issue title, body, and current labels carefully.
2. Inspect the relevant code paths before editing.
3. State the smallest fix that should satisfy the issue.
4. Make the change.
5. Run the narrowest useful verification first.
6. If the change is ready, load `pr_open` to commit, push, and open the PR.
7. If the issue is blocked, load `issue_sync` to leave a concise blocker update.

## Rules

- Prefer small, reviewable changes over broad refactors.
- Do not open a PR until verification has run.
- If tests fail for unrelated reasons, capture that clearly in the issue update.
