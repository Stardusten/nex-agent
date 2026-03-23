---
tracker:
  kind: github
  owner: gofenix
  repo: nex-agent
  ready_labels:
    - agent:ready
  running_label: nex:running
  review_label: nex:review
  failed_label: nex:failed
polling:
  interval_ms: 30000
workspace:
  root: .nex/orchestrator/worktrees
  agent_root: .nex/orchestrator/agents
agent:
  max_concurrent_agents: 1
  max_retry_backoff_ms: 300000
worker:
  command: mix nex.agent
  timeout_ms: 3600000
---
Load the repo-local skills before you start changing code.

Your job is to take one labeled GitHub issue from analysis to an open pull request:

1. Read the issue carefully and summarize the problem in your own words.
2. Inspect the repository before editing anything.
3. Make the smallest correct change that resolves the issue.
4. Run the narrowest useful verification first, then broader verification if needed.
5. If you need the repository-specific workflow, load `issue_to_pr`, `pr_open`, and `issue_sync`.
6. Open a pull request and make sure the PR body uses `Refs #<issue-number>`.
7. Leave the issue in a review-ready handoff state with a concise status summary.

Stop early only if the issue is blocked, unsafe, or missing information. If that happens, explain the blocker clearly in the issue update.
