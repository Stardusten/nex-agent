---
name: workbench-app-authoring
description: Use when accessing, explaining, creating, or modifying NexAgent Workbench apps or the built-in Workbench web UI, including notes apps, stock dashboards, project boards, local web tools, iframe app artifacts under workspace/workbench/apps, app manifests, permissions, static assets, URL/enablement checks, and optional reload.sh artifact refresh.
user-invocable: false
---

# Workbench App Authoring

Use this skill when accessing, explaining, creating, or modifying NexAgent Workbench apps.

## Workbench Mental Model

Workbench has two related surfaces:

- **Workbench Server**: the built-in local web UI and app host served by the NexAgent runtime when `gateway.workbench.enabled` is true.
- **Workbench Apps**: optional sandboxed iframe artifacts under `workspace/workbench/apps/<id>/`.

Do not conflate them. An empty `workspace/workbench/apps/` directory only means there are no custom iframe apps yet; it does not mean the built-in Workbench Server is absent.

Runtime context may include the current Workbench status. When enabled, the normal local URL is:

```text
http://127.0.0.1:<port>/workbench
```

The default normalized port is `50051`. If runtime context says Workbench is disabled, do not claim it is reachable; explain that the server is present in the runtime but not listening until enabled in the gateway workbench config.

The built-in Workbench shell includes system views such as Observability, Self Evolution, Configuration, and Sessions, plus the app launcher for custom iframe apps.

Keep dynamic Workbench facts out of steady prompt text. If the exact current port, enabled state, app list, or diagnostics matter, query the appropriate runtime/config/Workbench surface on demand instead of relying on cached prompt text.

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
workspace/workbench/apps/<id>/reload.sh     # optional
workspace/workbench/apps/<id>/src/          # optional
workspace/workbench/apps/<id>/dist/         # optional
```

Workbench runtime serves the manifest `entry` and app-local assets. Simple apps may edit `index.html` / `app.js` / `style.css` directly. Buildable apps may keep source under `src/**` and use app-local `reload.sh` to materialize runnable static artifacts such as `dist/index.html`.

Use the existing file-editing lane:

1. Discover app files with `find`.
2. Inspect app files with `read`.
3. Modify app files with `apply_patch`.
4. For simple static edits, activate changes by reloading the iframe in Workbench.
5. For buildable apps, use the controlled Workbench app reload/build capability when available to run `reload.sh`, then reload the iframe.

Core Workbench runtime changes under `lib/nex/agent/workbench/**`, `priv/workbench/**`, or tests are CODE-layer changes. Those still use `apply_patch`, then runtime activation through `self_update deploy` when activation is required.

Do not put domain-specific schemas into Workbench core or this builtin skill. Notes, stock dashboards, project boards, and similar products are ordinary Workbench apps with their own files and permissions.

Do not create a parallel editing lane for app files. The durable file truth source remains the workspace, and edits flow through the existing file tools.

Do not treat `reload.sh` as a generic shell tool. It is an app-local artifact refresh hook and must not be exposed to iframe apps through `window.Nex`.
