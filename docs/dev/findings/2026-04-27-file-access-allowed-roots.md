# 2026-04-27 File Access Allowed Roots

## Summary

File access roots are a TOOL-layer security contract, not a workspace contract.

`workspace` remains the single durable agent home for identity, memory, sessions, skills, tasks, and ControlPlane state. Extra project directories that `read`, `find`, and `apply_patch` may touch live under:

```json
{
  "tools": {
    "file_access": {
      "allowed_roots": ["/path/to/project"]
    }
  }
}
```

## Decided Contract

- `Config.file_access_allowed_roots/1` is the config accessor for this contract.
- `Security.allowed_roots/1`, `validate_path/2`, and `validate_write_path/2` require explicit tool/runtime context.
- There is no arity-0 or arity-1 compatibility API for path validation.
- Tool implementations must pass their runtime ctx into Security instead of reading config directly.
- `NEX_ALLOWED_ROOTS` remains a process-level override for the full allowed root set.

## Boundaries

- Do not make `workspace` an array.
- Do not treat extra allowed roots as additional agent workspaces.
- Do not let `read`, `find`, or `apply_patch` maintain separate file access logic.
- Root checks must match path boundaries; `/repo` does not allow `/repo-other`.

## Affected Tools

- `read` validates existing file/directory paths with `Security.validate_path/2`.
- `find` validates the explicit or default search scope with `Security.validate_path/2`.
- `apply_patch` validates add/update/delete/move targets with `Security.validate_write_path/2`.
