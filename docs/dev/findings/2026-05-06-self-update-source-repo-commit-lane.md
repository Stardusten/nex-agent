# 2026-05-06 Self Update Source Repo Commit Lane

## Conclusion

`self_update deploy` is runtime activation, not source history. Git commits must live on a separate owner-approved lane so the runtime can deploy quickly while source control still records the release, candidate, and evidence chain deliberately.

The source commit lane is:

```text
self_update deploy
-> deployed release with candidate/evidence metadata
-> self_update_commit prepare
-> owner approval
-> git add release files
-> git commit -F generated message
```

## Config Contract

The runtime config owns the optional source repo association:

```json
{
  "self_update": {
    "source_repo": {
      "path": "/path/to/nex-agent",
      "check_consistency": true
    }
  }
}
```

`check_consistency` defaults to `true`. When enabled, the committer verifies:

- configured source repo is a Git worktree
- configured git root canonically matches `CodeUpgrade.repo_root()`
- every deployed release file exists in the source repo
- each deployed file's current content matches the release `after_sha`

This keeps a mispointed checkout from receiving commits for a different running runtime. Disabling the check is an explicit escape hatch, not the default path.

## Evidence Contract

Deployed release records may carry:

```elixir
%{
  "candidate_id" => String.t(),
  "evidence_ids" => [String.t()]
}
```

The commit message is generated from:

- release id and release reason
- candidate summary and candidate id when present
- deployed file before/after hashes
- deploy test statuses
- ControlPlane observation summaries for referenced evidence ids

The commit message is deterministic enough for review, but still allows an explicit message override in `self_update_commit prepare/commit` when the owner needs a hand-written message.

## Approval Boundary

`self_update_commit commit` must call `Nex.Agent.Sandbox.Approval` before running Git. A successful deploy may prepare a proposal, but it must not automatically commit.

This preserves the key separation:

- deploy changes the running runtime after self_update checks pass
- commit records source history only after owner approval

Subagents may inspect and patch CODE, but the commit lane is owner-run only.

## Difference From Manual Local Commit And Restart

Manual local edit + commit + restart can still work operationally, but it bypasses the self-update chain:

- no `self_update` release id
- no release file before/after hash record
- no ControlPlane evidence references in the commit message
- no approval event for the source commit
- no deploy result visibility attached to the current runtime

The self-update source commit lane preserves the machine-readable trail needed for later rollback, review, and evolution.
