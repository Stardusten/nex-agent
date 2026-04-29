# 2026-04-29 Plugin Runtime Foundation

## 背景

NexAgent 已经有多个局部 registry / catalog：

- `Nex.Agent.Interface.Channel.Catalog` 管 Feishu / Discord channel type。
- `Nex.Agent.Turn.LLM.ProviderRegistry` 管 LLM provider adapter。
- `Nex.Agent.Capability.Tool.Registry` 管模型可见 tool。
- `Nex.Agent.Capability.Skills.Catalog` 管 builtin / workspace / project skill。
- `Nex.Agent.Interface.Workbench.Store` 管 workspace Workbench app manifest。
- `Nex.Agent.Conversation.Command.Catalog` 管跨 channel slash command。

这些机制说明项目已经在朝插件化方向演进，但现在每条能力线都有自己的注册入口、安装语义和诊断方式。继续按局部 registry 增长，会让新增 channel / provider / tool / Workbench view 时重复修改多个主链模块，也会让“安装、卸载、启停、观测、回滚”缺少统一语义。

插件化的目标不是把 NexAgent 变成一个只加载插件的空壳。NexAgent 仍然是长期运行的个人 agent runtime；插件系统只负责把非核心能力打包成可安装、可启停、可诊断的 contribution。

## 设计目标

1. 把非核心能力从硬编码列表逐步迁移成插件 contribution。
2. 保持 `Runtime.Snapshot` 是长期进程的唯一运行时世界观。
3. 安装、卸载、启停插件后，Gateway / Runner / Workbench / ControlPlane 看到同一个 runtime version。
4. 先支持 repo 内 builtin plugin 化，再支持 workspace/project plugin artifact。
5. 插件可以贡献能力，但不能绕过已有安全边界、配置入口、ControlPlane 观测和 runtime reload。
6. 插件系统必须服务长期运行和热重载，不只服务冷启动。

## 非目标

第一轮不做这些事：

- 任意外部 Hex / Git 包的动态依赖安装。
- 让 workspace plugin 热加载未审查的 Elixir 模块到核心 VM。
- 重新发明一套 tool execution lane、skill runtime、provider-native tool lane。
- 把 `Runtime` / `Runner` / `ControlPlane` / `Workspace` / `Security` 本身拆成插件。
- 为了迁移临时保留新旧双主线。

## 核心心智

插件是安装和启停单位，不是运行时真相源。

```text
plugin manifests / builtin plugin modules / workspace artifacts
        |
Plugin.Store
        |
Plugin.Catalog
        |
normalized contributions + diagnostics
        |
Runtime.Snapshot.plugins
        |
existing catalogs derive their registries from the snapshot
        |
Runner / Gateway / Workbench / ControlPlane
```

插件只把能力声明为 contribution；具体消费仍然走已有主链：

- channel 继续走 `Channel.Catalog` / `Gateway` / channel GenServer。
- provider 继续走 `ProviderRegistry` / `ProviderProfile` / `ReqLLM`。
- tool 继续走 `Tool.Registry`。
- skill 继续走 `Skills.Catalog` / `skill_get`。
- Workbench app 继续走 `Workbench.Store` / permissions / bridge。
- command 继续走 `Command.Catalog` / `Command.Parser`。

因此插件化后的目标不是删除这些 catalog，而是让它们从统一的 plugin contribution 投影生成。

## 核心与插件边界

### 保持核心

这些模块属于 NexAgent runtime 主链，不应作为普通插件卸载：

- `Nex.Agent.App.Application`
- `Nex.Agent.Runtime`
- `Nex.Agent.Runtime.Watcher`
- `Nex.Agent.Runtime.Reconciler`
- `Nex.Agent.Runtime.Snapshot`
- `Nex.Agent.Runtime.Config`
- `Nex.Agent.Runtime.Workspace`
- `Nex.Agent.Sandbox.Security`
- `Nex.Agent.Turn.ContextBuilder`
- `Nex.Agent.Turn.Runner`
- `Nex.Agent.Conversation.InboundWorker`
- `Nex.Agent.Conversation.Session`
- `Nex.Agent.Conversation.SessionManager`
- `Nex.Agent.Conversation.RunControl`
- `Nex.Agent.ControlPlane.*`
- `Nex.Agent.Capability.Tool.Registry`
- `Nex.Agent.Capability.Skills.Catalog`
- `Nex.Agent.Interface.Channel.Catalog`
- `Nex.Agent.Turn.LLM.ProviderRegistry`
- `Nex.Agent.Interface.Workbench.Server`
- `Nex.Agent.Interface.Workbench.Router`
- `Nex.Agent.Interface.Workbench.Permissions`

这些是 plugin host。它们负责消费插件贡献、执行安全检查、发布 diagnostics、维持 runtime 一致性。

### 优先插件化

这些能力适合先作为 builtin plugin 拆出：

- `channel.feishu`
  - Feishu channel spec
  - channel GenServer / ws client
  - IM profile / renderer / streaming converter
  - outbound media / card builder
  - `builtin:lark-feishu-ops` skill
- `channel.discord`
  - Discord channel spec
  - channel GenServer / ws client
  - IM profile / renderer / streaming converter
- `provider.*`
  - Anthropic
  - OpenAI
  - OpenAI-compatible
  - OpenRouter
  - Ollama
  - OpenAI Codex
- `tool.web`
  - `web_search`
  - `web_fetch`
  - search backend selection
- `tool.image-generation`
  - `image_generation`
  - image backend selection
- `tool.advisor`
  - `ask_advisor`
- `tool.memory`
  - memory status / rebuild / consolidate / write tools
  - memory-and-evolution builtin skill routing
- `tool.self_evolution`
  - `evolution_candidate`
  - self-evolution Workbench projection
- `workbench.system.*`
  - Sessions view
  - Scheduled Tasks view
  - Skills view
  - Evolution view
  - Notes bridge

Builtin plugin ids should be frozen before implementation starts. First batch ids:

```text
builtin:channel.feishu
builtin:channel.discord
builtin:provider.anthropic
builtin:provider.openai
builtin:provider.openai-compatible
builtin:provider.openrouter
builtin:provider.ollama
builtin:provider.openai-codex
builtin:provider.openai-codex-custom
builtin:tool.web
builtin:tool.image-generation
builtin:tool.advisor
builtin:tool.memory
builtin:tool.evolution
builtin:tool.cron
builtin:skill.nex-code-maintenance
builtin:skill.runtime-observability
builtin:skill.memory-and-evolution-routing
builtin:skill.lark-feishu-ops
builtin:skill.workbench-app-authoring
```

## Plugin Manifest 草案

插件 manifest 第一版应该保持窄而可验证：

```json
{
  "id": "builtin:channel.feishu",
  "title": "Feishu Channel",
  "version": "0.1.0",
  "enabled": true,
  "source": "builtin",
  "description": "Feishu/Lark chat gateway, rendering, media, and operational skill.",
  "contributes": {
    "channels": [
      {
        "type": "feishu",
        "spec_module": "Nex.Agent.Interface.Channel.Specs.Feishu"
      }
    ]
  }
}
```

Builtin plugins may reference compiled modules because they ship with repo CODE; their modules live under the owning `priv/plugins/builtin/<plugin-id>/lib` package and are compiled by Mix. Workspace/project plugins should not reference arbitrary Elixir modules until a reviewed code loading contract exists. They can contribute data/artifact surfaces first, such as skills and Workbench apps.

## Contribution Kinds

### `channels`

Channel contribution wraps existing channel spec contract:

```elixir
%{
  "kind" => "channel",
  "plugin_id" => String.t(),
  "type" => String.t(),
  "spec_module" => module()
}
```

`Channel.Catalog` should eventually read channel specs from plugin contributions. Unknown/disabled plugin channels must surface diagnostics through config/runtime, not crash unrelated channels.

### `providers`

Provider contribution wraps existing provider adapter contract:

```elixir
%{
  "kind" => "provider",
  "plugin_id" => String.t(),
  "type" => String.t(),
  "adapter_module" => module()
}
```

`ProviderRegistry` should resolve adapters from enabled plugin contributions. Unknown provider types continue to use the default adapter only when config explicitly allows the existing generic behavior.

### `tools`

Tool contribution wraps modules implementing `Nex.Agent.Capability.Tool.Behaviour`:

```elixir
%{
  "kind" => "tool",
  "plugin_id" => String.t(),
  "name" => String.t(),
  "module" => module(),
  "surfaces" => ["all", "base", "follow_up", "subagent", "cron"]
}
```

Tool surfaces should move out of hardcoded allowlists in `Tool.Registry`. The registry remains the only executor and ControlPlane observation source.

### `skills`

Skill contribution points to `SKILL.md` source:

```elixir
%{
  "kind" => "skill",
  "plugin_id" => String.t(),
  "id" => String.t(),
  "path" => String.t(),
  "source" => "builtin" | "workspace" | "project"
}
```

Skill progressive disclosure remains unchanged: prompt cards first, `skill_get(id)` body later.

### Deferred: `workbench_apps`

Workbench app contribution points to existing app manifest artifacts:

```elixir
%{
  "kind" => "workbench_app",
  "plugin_id" => String.t(),
  "app_id" => String.t(),
  "manifest_path" => String.t()
}
```

The Workbench host and permissions remain core. App-specific UI and bridge consumers live in plugin/app artifacts.

This contribution kind is not frozen in Phase 20 until `Workbench.Store` has a plugin-derived consumer. A manifest-only `workbench_app` contribution without a consumer would create a second app catalog beside `workspace/workbench/apps`.

### Deferred: `workbench_views`

Builtin system views can be migrated after app artifacts:

```elixir
%{
  "kind" => "workbench_view",
  "plugin_id" => String.t(),
  "id" => String.t(),
  "label" => String.t(),
  "router_module" => module(),
  "permissions" => [String.t()]
}
```

This should not make `Workbench.Router` a generic plug router in the first step. It should first allow core to dispatch known view contributions through a bounded table.

This contribution kind is not frozen in Phase 20. Workbench system views stay core until a bounded view contribution consumer and tests exist.

### `commands`

Command contribution wraps existing command definitions:

```elixir
%{
  "kind" => "command",
  "plugin_id" => String.t(),
  "name" => String.t(),
  "description" => String.t(),
  "usage" => String.t(),
  "bypass_busy?" => boolean(),
  "native_enabled?" => boolean(),
  "handler" => String.t(),
  "channels" => [String.t()]
}
```

`/stop` and core run-control commands should stay core until command handler ownership is fully explicit. JSON manifests do not carry atoms; first command contributions may only bind `handler` to a bounded core/builtin handler table. Workspace/project command plugins may describe commands, but they must not provide executable handlers until a separate execution contract exists.

### Deferred: `subagents`

Subagent profile contribution is deferred until `Nex.Agent.Capability.Subagent.Profiles` has a plugin-derived consumer. Phase 20 may inventory subagent profiles, but must not freeze a manifest shape that no runtime path consumes.

## Install Sources

第一版 source 顺序：

1. `builtin`
   - packaged with repo
   - can reference compiled modules
   - default enabled unless explicitly disabled by runtime config
2. `workspace`
   - under `workspace/plugins/<id>/nex.plugin.json`
   - can contribute skills and Workbench apps first
   - no arbitrary VM code loading in Phase 20
3. `project`
   - repo-local plugin artifacts for the active project
   - same restrictions as workspace until reviewed

未来可以增加 installer，把 remote package materialize 成 workspace plugin artifact。installer 不是 Phase 20 的核心。

## Runtime Reload Contract

插件 reload 必须遵守现有 Runtime 原则：

```text
load config from config_path
resolve workspace via opts/config/default
load plugin catalog using workspace + normalized plugin config
derive channel/provider/tool/skill/command contributions
build prompt/tool/skill/command/channel/provider projections plus existing Workbench data
validate snapshot candidate
publish one runtime version
reconcile long-lived consumers
```

一个 runtime version 必须包含一致的：

- enabled plugins
- plugin diagnostics
- channel specs
- provider adapters
- tool definitions by surface
- skill catalog prompt
- command catalog
- existing Workbench runtime/app data

不能出现 prompt 来自新插件、tool registry 仍来自旧插件集合的混合状态。

`Runtime.Watcher` must include plugin manifests in the reload trigger surface:

```text
priv/plugins/builtin/**/nex.plugin.json
workspace/plugins/**/nex.plugin.json
project plugin manifests when configured
```

Changing a plugin manifest or contribution file must trigger one runtime reload. Gateway, Workbench, Runner, and any runtime subscribers must observe the same published runtime version for that change.

## Config 草案

第一版可以把启停放入 existing config root：

```json
{
  "plugins": {
    "disabled": [
      "builtin:tool.advisor"
    ],
    "enabled": {
      "workspace:notes": true
    }
  }
}
```

原则：

- builtin plugin 默认启用，除非被 disabled。
- workspace/project plugin 默认不启用，除非 manifest 和 config 同时允许，或 later owner approval 明确安装。
- disabled plugin 的 contribution 不进入 runtime 投影。
- disabled 永远优先于 enabled；同一个 plugin 同时出现在 disabled 和 enabled 时必须视为 disabled，并产生 bounded diagnostic。
- config normalization 仍属于 `Nex.Agent.Runtime.Config`，不要让插件模块自己读 config 文件。

Provider config needs a separate availability check. `Config` should preserve raw provider type strings and report diagnostics when the selected provider plugin is unavailable. Unknown provider types must not silently become `:openai`; generic/default adapter use is allowed only for an explicit generic/openai-compatible contract.

## 安全与观测

插件系统必须保留三条边界：

1. CODE plugin 和 workspace artifact plugin 分开。
2. 权限声明和 owner grant 分开。
3. 安装/启停结果和运行时调用结果都写 ControlPlane。

建议 observation tags：

- `plugin.catalog.loaded`
- `plugin.catalog.failed`
- `plugin.enabled`
- `plugin.disabled`
- `plugin.contribution.accepted`
- `plugin.contribution.rejected`

Workbench app 权限仍由 `Workbench.Permissions` enforcement。Tool 调用仍由 `Tool.Registry` enforcement。File access 仍由 `Nex.Agent.Sandbox.Security` enforcement。

## 迁移路线

### Stage 1：抽象和 inventory

新增 plugin manifest/store/catalog/snapshot 字段，只读当前硬编码 catalog，生成 inventory 和 diagnostics。现有行为不改。

目标是回答：

- 当前哪些能力已经有清楚 owner？
- 哪些 hardcoded allowlist 应改为 contribution metadata？
- 哪些模块不能卸载？
- 哪些 plugin disable 会影响热重载或长期进程？

### Stage 2：catalog 接入 plugin contributions

让 `Channel.Catalog`、`ProviderRegistry`、`Tool.Registry`、`Skills.Catalog`、`Command.Catalog` 逐步从 plugin contribution 读取。每次只迁移一条 catalog，删除对应硬编码平行列表。

### Stage 3：物理迁移非核心能力

把 Feishu / Discord / provider / tool / builtin skill 等非核心能力组织成 builtin plugin。目录和模块可以分批迁移，但每一批必须保持 runtime snapshot、Workbench config、prompt 和 tests 同步。

## Open Questions

1. Workspace/project plugin 何时允许贡献可执行 Elixir module？
2. Plugin manifest 是否需要 lockfile 记录安装来源和 checksum？
3. Workbench system view contribution 要做到什么程度，才允许移除 `Router` 中的硬编码分支？
4. Tool surfaces 应该写在 manifest，还是仍由 tool module 自身声明？
5. Builtin plugin disable 是否允许关闭 `read/find/apply_patch/self_update` 这类高风险但核心自维护需要的 tools？

这些问题不阻塞 Phase 20 Stage 1。Stage 1 只冻结 host 抽象、enablement precedence、watcher trigger 面和 inventory。
