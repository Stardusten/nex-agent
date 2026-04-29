# 2026-04-28 Workbench App Artifact Reload Contract

## Summary

Workbench apps should follow an Obsidian-plugin-like artifact model:

- the Workbench runtime serves a small set of standard static artifacts
- app source layout is app-owned and may be simple or complex
- an optional app-local `reload.sh` turns source into runnable artifacts
- NexAgent edits app files through `find` / `read` / `apply_patch`
- a future controlled app reload/build lane runs `reload.sh`; core CODE changes still use `self_update deploy`

This keeps Workbench apps evolvable by NexAgent itself without requiring an external coding agent or human terminal step after every source edit.

## Decided Contract

An app directory lives under:

```text
<workspace>/workbench/apps/<id>/
```

Required:

```text
nex.app.json
```

Standard runtime artifacts:

```text
index.html
app.js
style.css
assets/**
```

Optional source and build files:

```text
reload.sh
src/**
package.json
vite.config.*
dist/**
```

`nex.app.json` remains the runtime manifest. Its `entry` field points to the HTML file Workbench serves through `/app-frame/:id`; it defaults to `index.html`.

Simple apps may directly edit top-level `index.html`, `app.js`, and `style.css`. Complex apps may keep source under `src/**` and set `entry` to a generated artifact such as `dist/index.html`.

## `reload.sh` Semantics

`reload.sh` is app-local and optional.

It means:

```text
prepare this app directory so the manifest entry points at current runnable static artifacts
```

It does not mean:

```text
reload NexAgent core CODE
reload the browser iframe
run arbitrary user-requested shell commands
grant app permissions
write outside the app directory unless a later explicit contract allows it
```

The future controlled runner must:

- resolve app id through the Workbench app store
- run with cwd set to that app directory
- execute only that app's `reload.sh`
- enforce timeout and output limits
- record started / finished / failed ControlPlane observations
- return bounded stdout/stderr to the agent
- remain unavailable to iframe apps through the SDK bridge

The first runner should not become a generic shell tool. App source edits still flow through `find` / `read` / `apply_patch`; `reload.sh` only materializes app artifacts after those edits.

## Layer Boundary

Workbench app artifact work is a workspace artifact lane:

```text
find/read -> apply_patch -> workbench app reload/build -> iframe reload
```

Workbench core runtime work remains the CODE lane:

```text
find/read/reflect -> apply_patch -> self_update deploy
```

Do not route Workbench app source edits through `self_update deploy`. Do not route Workbench core changes through `reload.sh`.

## Notes App Implication

The notes app may use React, TypeScript, CodeMirror, Vite, or another frontend stack, but those are app-local source choices. Workbench core only needs the manifest entry and app-local static serving contract.

For the Obsidian-like notes app, the intended shape is:

```text
workbench/apps/notes/
  nex.app.json
  reload.sh
  index.html or dist/index.html
  app.js/style.css or dist/assets/**
  src/**
```

The note vault itself is not a second NexAgent workspace. It is an external data root exposed through bounded notes bridge methods and file-access security checks.

## Open Implementation Questions

- whether dependency installation is allowed inside `reload.sh` or requires a separate owner-approved package install lane
- exact ControlPlane tag names for app artifact reload lifecycle
- whether the shell should offer a separate "Run reload.sh" control, or only owner/agent authoring turns may trigger it
- whether app reload output should be surfaced in Workbench app diagnostics, ControlPlane only, or both
