# 2026-04-29 Plugin Runtime Boundary

## 结论

NexAgent 的插件系统应当把“非核心能力的安装、启停、诊断和 contribution 声明”收口，但不能成为新的运行时真相源。

冻结原则：

```text
Plugin = install/enable/disable package
Runtime.Snapshot = long-running process truth source
Catalog/Registry = capability-specific projection
ControlPlane = machine observation truth source
```

插件贡献能力，Runtime 统一投影能力，现有主链消费能力。任何插件化改动如果让 Gateway、Runner、Workbench 或 provider/tool/channel registry 各自读取插件文件，就判定为架构偏离。

## 为什么这样定

当前项目已经有多个一等 catalog：

- Channel spec catalog 已经把 channel type、format prompt、IM profile、renderer、Gateway module、Workbench config metadata 收口。
- Provider registry 已经把 provider-specific policy 收进 adapter。
- Tool registry 已经是模型可见 tool 和 deterministic execution 的唯一入口。
- Skill catalog 已经采用 progressive disclosure，不能回到 hidden runtime package 或 body preload。
- Workbench app runtime 已经采用 manifest + sandbox iframe + permission bridge。

这些不是要被插件系统替换的旧系统。它们是插件 host 的消费面。插件系统的正确角色，是把这些 registry 的输入统一成 contribution。

## Core Host 边界

以下能力属于插件宿主，不能作为普通插件拆走：

- OTP application/supervisor 主树
- `Runtime` / `Runtime.Watcher` / `Runtime.Reconciler`
- `Runtime.Snapshot`
- `Config` normalization and accessors
- `Workspace`
- `Security`
- `Runner`
- `InboundWorker`
- `SessionManager`
- `RunControl`
- `ControlPlane`
- `Tool.Registry`
- `Skills.Catalog`
- `Channel.Catalog`
- `ProviderRegistry`
- Workbench server/router/permission enforcement

这些模块可以被重构以消费 plugin contribution，但不能被普通启停配置卸载。

## Plugin Contribution 边界

插件 contribution 第一版覆盖：

- channels
- providers
- tools
- skills
- slash commands

每种 contribution 必须有一个已有主链 consumer。没有 consumer 的 contribution 不能只停留在 manifest 里。

Workbench app、Workbench system view、subagent profile contribution 暂不进入 Phase 20 冻结列表。它们只能作为 inventory/deferred design 出现，直到对应 consumer 和 tests 一起落地。

## Builtin 与 Workspace 插件分层

Builtin plugin 是 repo CODE layer，允许声明已编译模块：

```text
priv/plugins/builtin/<id>/nex.plugin.json
lib/nex/agent/plugins/builtin/**
```

Workspace/project plugin 第一版是 artifact layer，只允许贡献不需要 VM code loading 的能力：

- skill markdown
- Workbench app manifest/static assets
- data/config metadata

在没有 code loading safety contract 前，workspace/project plugin 不得把任意 Elixir module 加载进长期 VM。

## Runtime Snapshot Contract

`Runtime.Snapshot` 必须新增 `plugins` 投影：

```elixir
%{
  manifests: [map()],
  enabled: [String.t()],
  contributions: %{
    channels: [map()],
    providers: [map()],
    tools: [map()],
    skills: [map()],
    commands: [map()]
  },
  diagnostics: [map()],
  hash: String.t()
}
```

`plugins.hash` 必须参与 runtime version 变化判断。插件启停、manifest 变化、contribution 变化都必须产生新的 runtime snapshot。

`Runtime.Watcher` 必须把 plugin manifest 目录纳入 runtime reload 触发面。`priv/plugins/builtin/**/nex.plugin.json`、`workspace/plugins/**/nex.plugin.json` 和后续 project plugin manifests 变化后，必须触发 runtime reload，并让 Gateway/Workbench/runtime subscribers 观察到同一个新 runtime version。

Runtime build order 冻结为：

```text
load config from config_path
resolve workspace via opts/config/default
load plugin catalog using workspace + normalized plugin config
derive plugin contributions
build existing runtime projections from those contributions
publish one snapshot
```

不得先扫描 workspace plugin 再决定 config workspace，也不得让 plugin module 自己读取 config。

## Provider Availability

Provider type normalization must not hide unavailable or unknown providers.

Required behavior:

- `Config` preserves raw provider type strings.
- plugin-derived provider catalog decides availability.
- disabled provider plugin produces config/runtime diagnostics.
- Runner must not use a model whose provider plugin is unavailable.
- unknown provider types do not silently become `:openai`.
- default/generic provider adapter use is allowed only for explicit generic/openai-compatible contract.

## Tool Registry Source

Tool definitions and tool execution map must be same-source.

Disabling a tool plugin must remove the tool from:

- `definitions_all`
- `definitions_follow_up`
- `definitions_subagent`
- `definitions_cron`
- `Tool.Registry.execute/3`

It is a bug if the snapshot hides a tool from the model but direct registry execution can still run it by name.

## Command Handler Boundary

Command contribution handler ids are strings, not atoms from JSON.

First implementation may only bind command handlers through a bounded core/builtin handler table. Workspace/project command plugins may not contribute executable handlers until a reviewed execution contract exists.

## Review Checks

Review 时应拒绝这些实现：

- 插件模块自己读取 `~/.nex/agent/config.json` 或 runtime 文件。
- Runner / Gateway / Workbench 分别扫描 plugin 目录。
- Tool registry 增加第二条 execution lane。
- Tool definitions and `execute/3` use different source maps.
- Disabled provider plugin is normalized into another provider instead of producing diagnostics.
- Provider adapter 插件绕过 `ProviderProfile` facade。
- Channel 插件绕过 `Channel.Spec` contract。
- Skill 插件绕过 `Skills.Catalog` / `skill_get` progressive disclosure。
- Workbench app 插件绕过 manifest declaration、owner grant、bridge enforcement。
- Workbench app/view/subagent contribution is accepted before a consumer exists.
- 为迁移保留新旧两个并行 truth source。
- 插件 disable 后只有 cold start 生效，runtime reload 不生效。

## 第一批应迁移能力

Phase 20 后续迁移优先顺序：

1. Channel: Feishu、Discord。
2. Provider adapters: Anthropic、OpenAI、OpenAI-compatible、OpenRouter、Ollama、OpenAI Codex。
3. Tool families: web/image/advisor/memory/evolution/cron/executor/custom tool management。
4. Builtin skills: `nex-code-maintenance`、`runtime-observability`、`memory-and-evolution-routing`、`lark-feishu-ops`、`workbench-app-authoring`。
5. Workbench system views only after bridge/view contribution consumer and tests exist.

## 不变项

- Runtime snapshot 仍是长期进程一致性边界。
- ControlPlane observation 仍是机器真相源。
- File access roots 仍走 `Nex.Agent.Sandbox.Security`。
- Workbench permission grant 不写进 plugin manifest。
- Tool backend selection 仍在本地 tool 内部，不引入 provider-native tool lane。
- Skills 仍是 cards + `skill_get(id)`，不恢复 SkillRuntime package execution。
