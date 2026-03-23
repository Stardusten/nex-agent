---
name: pr_open
description: Create a branch commit, push it, and open a GitHub pull request linked to the issue.
user-invocable: true
requires:
  bins:
    - git
    - gh
---

# PR Open

Use this skill when code changes are complete and verified and you need to create the branch commit and pull request.

## Workflow

1. Check `git status --short`.
2. Review the staged or unstaged changes before committing.
3. Commit with a concise message that reflects the issue.
4. Push the branch to origin.
5. Open a PR with `gh pr create`.
6. Make sure the PR body includes `Refs #<issue-number>`.
7. Load `issue_sync` to leave a concise issue update containing the PR URL and verification summary.

## Rules

- Do not use `Closes #<issue-number>` by default.
- Keep the PR body short and concrete.
- Mention the verification commands you actually ran.
