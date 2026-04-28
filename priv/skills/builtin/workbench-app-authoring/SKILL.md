---
name: workbench-app-authoring
description: Use when creating or modifying Workbench static iframe apps under workspace/workbench/apps with find/read/apply_patch.
user-invocable: false
---

# Workbench App Authoring

Use this skill when creating or modifying a NexAgent Workbench app.

Workbench apps are workspace artifacts, not framework CODE. App files live under:

```text
workspace/workbench/apps/<id>/
```

Expected app shape:

```text
workspace/workbench/apps/<id>/nex.app.json
workspace/workbench/apps/<id>/index.html
workspace/workbench/apps/<id>/app.js
workspace/workbench/apps/<id>/style.css
workspace/workbench/apps/<id>/assets/
```

Use the existing code-editing lane:

1. Discover app files with `find`.
2. Inspect app files with `read`.
3. Modify app files with `apply_patch`.
4. Activate app artifact changes by reloading the iframe in Workbench.

Core Workbench runtime changes under `lib/nex/agent/workbench/**`, `priv/workbench/**`, or tests are CODE-layer changes. Those still use `apply_patch`, then runtime activation through `self_update deploy` when activation is required.

Do not put domain-specific schemas into Workbench core or this builtin skill. Notes, stock dashboards, project boards, and similar products are ordinary Workbench apps with their own files and permissions.

Do not create a parallel editing lane for app files. The durable file truth source remains the workspace, and edits flow through the existing file tools.
