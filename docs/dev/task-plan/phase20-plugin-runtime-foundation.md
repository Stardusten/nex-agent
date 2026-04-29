# Phase 20 Plugin Runtime Foundation

## 当前状态

当前 repo 已经有多个局部 catalog / registry：

- `Nex.Agent.Interface.Channel.Catalog` 静态列出 Feishu / Discord specs。
- `Nex.Agent.Turn.LLM.ProviderRegistry` 静态列出 provider adapter。
- `Nex.Agent.Capability.Tool.Registry` 静态列出 default tools，并在 registry 内硬编码 cron/subagent surfaces。
- `Nex.Agent.Capability.Skills.Catalog` 直接扫描 builtin/workspace/project skills。
- `Nex.Agent.Conversation.Command.Catalog` 静态列出 slash commands。
- `Nex.Agent.Interface.Workbench.Store` 扫描 workspace Workbench apps，但 system views 和 bridge methods 仍硬编码在 Workbench core。
- `Nex.Agent.Runtime.Watcher` 只递归扫描 workspace `skills/` 和 `tools/`，plugin manifest 变化不会触发 runtime reload。
- `Nex.Agent.Runtime.Config` 硬编码 provider type allowlist，未知 provider type 会落到 `:openai`，这会掩盖 disabled/unknown provider plugin。

这些入口各自可用，但缺少统一的安装、启停、诊断和 runtime 投影模型。继续增加 Feishu/Discord/provider/tool/Workbench 能力会扩大硬编码列表和并行 truth source。

## 完成后必须达到的结果

Phase 20 完成时仓库必须满足：

1. 新增 plugin host 抽象，插件 manifest / store / catalog / contribution normalization 都有明确 CODE 层入口。
2. `Runtime.Snapshot` 携带 `plugins` 投影，plugin diagnostics/hash 进入 runtime world view。
3. Stage 1 完成当前能力 inventory，不改变现有行为。
4. Stage 2 让现有 catalog/registry 从 plugin contributions 派生，删除对应硬编码平行列表。
5. Stage 3 把 Feishu / Discord / provider adapters / tool families / builtin skills 物理组织成 builtin plugins。
6. 插件启停必须通过 runtime reload 生效，并触发必要的 Gateway reconcile / session stale rebuild。
7. 插件 contribution 不允许绕过现有 channel/provider/tool/skill/workbench/security/control-plane 主链。
8. Workspace/project plugin 在本 phase 不允许动态加载未审查 Elixir module。
9. `Runtime.Watcher` 把 plugin manifest 纳入 reload 触发面，manifest 变化会产生新的 `plugins.hash` 和 runtime version。
10. Provider availability 走 plugin-derived provider catalog；禁用 provider plugin 后 config/runtime 产生 diagnostics，Runner 不使用该 provider。
11. Tool definitions 和 `Tool.Registry.execute/3` 使用同一个 plugin-derived execution map；禁用 tool 后直接执行也返回 unknown tool。
12. 文档、tests、Workbench config/diagnostics 同步反映 plugin runtime contract。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/designs/2026-04-29-plugin-runtime-foundation.md`
- `docs/dev/findings/2026-04-29-plugin-runtime-boundary.md`
- `docs/dev/findings/2026-04-16-runtime-reload-architecture.md`
- `docs/dev/findings/2026-04-25-local-tool-backend-selection.md`
- `docs/dev/findings/2026-04-28-skill-progressive-disclosure-catalog.md`
- `docs/dev/task-plan/phase12-llm-provider-adapter-architecture.md`
- `docs/dev/task-plan/phase19-channel-spec-registry-and-prompt-governance.md`
- `lib/nex/agent/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/runtime/watcher.ex`
- `lib/nex/agent/config.ex`
- `lib/nex/agent/workspace.ex`
- `lib/nex/agent/channel/catalog.ex`
- `lib/nex/agent/llm/provider_registry.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/skills/catalog.ex`
- `lib/nex/agent/command/catalog.ex`
- `lib/nex/agent/workbench/router.ex`
- `lib/nex/agent/workbench/store.ex`
- `lib/nex/agent/workbench/permissions.ex`
- `test/nex/agent/runtime_test.exs`
- `test/nex/agent/runtime_watcher_test.exs`
- `test/nex/agent/channel_spec_test.exs`
- `test/nex/agent/llm/provider_registry_test.exs`
- `test/nex/agent/tool_alignment_test.exs`
- `test/nex/agent/skills_test.exs`
- `test/nex/agent/workbench/server_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. Plugin host module paths：

```text
lib/nex/agent/plugin.ex
lib/nex/agent/plugin/manifest.ex
lib/nex/agent/plugin/store.ex
lib/nex/agent/plugin/catalog.ex
lib/nex/agent/plugin/contribution.ex
```

Module names：

```elixir
Nex.Agent.Extension.Plugin
Nex.Agent.Extension.Plugin.Manifest
Nex.Agent.Extension.Plugin.Store
Nex.Agent.Extension.Plugin.Catalog
Nex.Agent.Extension.Plugin.Contribution
```

2. Manifest 最小 struct：

```elixir
defmodule Nex.Agent.Extension.Plugin.Manifest do
  @type source :: :builtin | :workspace | :project

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          version: String.t(),
          enabled: boolean(),
          source: source(),
          description: String.t(),
          path: String.t() | nil,
          contributes: map(),
          metadata: map()
        }

  defstruct [
    :id,
    :title,
    :version,
    :enabled,
    :source,
    :description,
    :path,
    contributes: %{},
    metadata: %{}
  ]
end
```

3. Plugin id contract：

```text
builtin:<name>
workspace:<name>
project:<name>
```

`<name>` must match:

```elixir
~r/^[a-z][a-z0-9_.-]{1,79}$/
```

4. Builtin plugin id list：

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

5. Runtime snapshot plugin projection：

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

`Runtime.Snapshot` must expose this as `snapshot.plugins`.

Workbench app、Workbench system view、subagent profile contribution are deferred and must not be accepted as active Phase 20 contributions until their consumers are implemented.

6. Contribution normalized shape：

```elixir
%{
  "kind" => String.t(),
  "plugin_id" => String.t(),
  "id" => String.t(),
  "source" => "builtin" | "workspace" | "project",
  "attrs" => map()
}
```

Each consumer may project `attrs` into stricter existing structs, but `plugin_id`, `kind`, and `id` must remain available for diagnostics and Workbench.

7. Builtin plugin directory：

```text
priv/plugins/builtin/<name>/nex.plugin.json
```

First builtin plugin manifests may reference existing compiled modules. They must not copy or fork module implementations.

8. Workspace plugin directory：

```text
workspace/plugins/<name>/nex.plugin.json
```

In Phase 20, workspace/project plugin may contribute only non-VM-code artifacts:

- skills
- Workbench apps
- metadata

They must not declare `module` references that are loaded through `Code.compile_file/1` or `Code.compile_string/1`.

9. Config plugin enablement minimal shape：

```json
{
  "plugins": {
    "disabled": ["builtin:tool.advisor"],
    "enabled": {
      "workspace:notes": true
    }
  }
}
```

`Nex.Agent.Runtime.Config` owns normalization. Plugin modules must not read config files.

Enablement precedence is frozen:

```text
disabled always wins
builtin plugin default enabled
workspace/project plugin default disabled
workspace/project plugin requires valid manifest and config enablement
```

If a plugin id appears in both `disabled` and `enabled`, the plugin is disabled and a bounded diagnostic is emitted.

10. Runtime build order after Stage 1：

```text
load config from config_path
resolve workspace via opts/config/default
load plugin catalog using workspace + normalized plugin config
build command definitions
load subagent profiles
build skills
build prompt
build tool definitions
load hooks
build workbench data
assemble snapshot
```

Stage 2 may move command/skills/tools/channel/provider inputs behind plugin-derived catalog data, but each published runtime version must remain internally consistent.

11. Runtime watcher plugin trigger surface:

```text
priv/plugins/builtin/**/nex.plugin.json
workspace/plugins/**/nex.plugin.json
project plugin manifests when configured
```

Changing a plugin manifest must trigger runtime reload, change `snapshot.plugins.hash`, and notify runtime subscribers with the same new runtime version.

12. First contribution kinds are frozen to:

```elixir
~w(channels providers tools skills commands)
```

Adding a new kind requires updating manifest normalization, catalog projection, snapshot tests, and docs.

13. Command handler contract:

```elixir
%{
  "handler" => String.t()
}
```

Command handler ids from plugin manifests are strings. First implementation may only resolve them through a bounded core/builtin handler table. Workspace/project command plugins may not provide executable handlers.

14. Provider availability contract:

`Nex.Agent.Runtime.Config` must preserve raw provider type strings. Provider availability is checked against plugin-derived provider catalog after plugin load. Unknown or disabled provider types produce diagnostics and must not silently become `:openai`. Generic/default adapter use is allowed only for explicit generic/openai-compatible contract.

15. Tool registry same-source contract:

Tool definitions and execution map must derive from the same enabled plugin contribution set. Disabling a tool plugin removes it from all definition surfaces and from `Tool.Registry.execute/3`.

## 执行顺序 / stage 依赖

- Stage 1：Plugin host 抽象和 inventory。无行为迁移。
- Stage 2：现有 catalog/registry 接入 plugin contributions。每条 catalog 单独迁移并删掉旧平行硬编码入口。
- Stage 3：物理迁移 Feishu / Discord / provider / tool / skill 非核心能力为 builtin plugins。

## Stage 1

### 前置检查

- 确认 Phase 19 channel spec registry 已落地。
- 确认 Runtime snapshot 当前 tests 通过。
- 确认没有正在进行的 provider/tool/channel 大迁移分支。

### 这一步改哪里

- `lib/nex/agent/plugin.ex`
- `lib/nex/agent/plugin/manifest.ex`
- `lib/nex/agent/plugin/store.ex`
- `lib/nex/agent/plugin/catalog.ex`
- `lib/nex/agent/plugin/contribution.ex`
- `lib/nex/agent/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/runtime/watcher.ex`
- `lib/nex/agent/config.ex`
- `lib/nex/agent/workspace.ex`
- `test/nex/agent/plugin/manifest_test.exs`
- `test/nex/agent/plugin/store_test.exs`
- `test/nex/agent/plugin/catalog_test.exs`
- `test/nex/agent/runtime_test.exs`
- `test/nex/agent/runtime_watcher_test.exs`
- `docs/dev/findings/2026-04-29-plugin-runtime-boundary.md`

### 这一步要做

新增 plugin manifest/store/catalog/contribution host。

`Plugin.Store.load_all/1` 第一版读取：

```text
priv/plugins/builtin/*/nex.plugin.json
workspace/plugins/*/nex.plugin.json
project plugin dir when configured
```

Stage 1 只生成 inventory，不改变任何现有 catalog 输入。

`Runtime.Snapshot` 新增：

```elixir
plugins: %{
  manifests: [],
  enabled: [],
  contributions: %{
    channels: [],
    providers: [],
    tools: [],
    skills: [],
    commands: []
  },
  diagnostics: [],
  hash: ""
}
```

为当前硬编码能力生成 inventory diagnostics，例如：

```elixir
%{
  "kind" => "inventory",
  "code" => "hardcoded_catalog_entry",
  "catalog" => "channel",
  "id" => "feishu",
  "recommended_plugin_id" => "builtin:channel.feishu"
}
```

`Runtime.Watcher` 增加 plugin manifest 触发面：

```text
priv/plugins/builtin/**/nex.plugin.json
workspace/plugins/**/nex.plugin.json
```

`Runtime.reload/1` build order 改为先读 config、再解析 workspace、再用 workspace 和 normalized plugin config 加载 plugin catalog。

### 实施注意事项

- 不改变 `Channel.Catalog.all/0`、`ProviderRegistry.known_providers/0`、`Tool.Registry` default tools 的实际来源。
- 不让 plugin store 读取敏感 config 文件。
- 不在 Stage 1 加载 workspace plugin Elixir code。
- Diagnostics 必须 bounded，坏 manifest 不阻塞 runtime reload。
- `Workspace.ensure!/1` 增加 `plugins` 目录。
- `Runtime.Watcher` 不直接 normalize plugin contribution；它只负责检测文件变化并触发同一条 runtime reload 主链。
- Stage 1 不接受 active `workbench_apps`、`workbench_views`、`subagents` contribution；这些只能作为 inventory/deferred diagnostics。

### 本 stage 验收

- Runtime snapshot 有 `plugins` 字段。
- 有效 builtin/workspace manifest 会进入 `snapshot.plugins.manifests`。
- invalid manifest 变成 diagnostics，不导致 runtime reload fail。
- 修改 `workspace/plugins/<id>/nex.plugin.json` 会触发 runtime reload。
- 修改 `priv/plugins/builtin/<id>/nex.plugin.json` 会触发 runtime reload。
- plugin manifest 变化会改变 `snapshot.plugins.hash`。
- Gateway / Workbench / runtime subscribers 收到的是同一个新 runtime version。
- 当前 channel/provider/tool/skill/command 行为不变。
- Inventory 能列出 Feishu/Discord/provider/default tools/builtin skills 的建议 plugin id。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/plugin test/nex/agent/runtime_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/runtime_watcher_test.exs test/nex/agent/runtime_reconciler_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/channel_spec_test.exs test/nex/agent/llm/provider_registry_test.exs test/nex/agent/tool_alignment_test.exs test/nex/agent/skills_test.exs
/Users/krisxin/.local/bin/mise exec -- mix compile --warnings-as-errors
```

如本机没有 mise path，可使用 `/opt/homebrew/bin/mix` 跑同等命令。

## Stage 2

### 前置检查

- Stage 1 tests 通过。
- `snapshot.plugins` 能稳定表达 enabled plugin 和 diagnostics。
- Inventory 已确认每条迁移能力的 owner plugin id。

### 这一步改哪里

- `priv/plugins/builtin/**/nex.plugin.json`
- `lib/nex/agent/plugin/catalog.ex`
- `lib/nex/agent/channel/catalog.ex`
- `lib/nex/agent/config.ex`
- `lib/nex/agent/llm/provider_registry.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/skills/catalog.ex`
- `lib/nex/agent/command/catalog.ex`
- `lib/nex/agent/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/workbench/config_panel.ex`
- `test/nex/agent/plugin/catalog_test.exs`
- `test/nex/agent/channel_spec_test.exs`
- `test/nex/agent/config_test.exs`
- `test/nex/agent/llm/provider_registry_test.exs`
- `test/nex/agent/tool_alignment_test.exs`
- `test/nex/agent/skills_test.exs`
- `test/nex/agent/context_builder_test.exs`
- `test/nex/agent/runtime_test.exs`
- `test/nex/agent/workbench/server_test.exs`

### 这一步要做

按以下顺序迁移 catalog 输入：

1. Channel catalog
   - Feishu/Discord specs 从 enabled plugin contributions 派生。
   - 删除 `Channel.Catalog.all/0` 中静态列表。
2. Provider registry
   - provider adapters 从 enabled plugin contributions 派生。
   - 删除 `@adapters` 静态列表。
   - `Config` 保留 raw provider type，并通过 plugin-derived provider catalog 做 availability diagnostics。
   - unknown/disabled provider type 不能落到 `:openai`。
3. Tool registry
   - default tools 从 enabled plugin contributions 派生。
   - tool surfaces 从 contribution metadata 或 tool module callback 派生。
   - 删除 `@default_tools`、`@cron_tools`、`@subagent_tools` 平行 allowlist。
   - registry execution map 与 definitions 使用同一个 enabled contribution 投影更新。
4. Skills catalog
   - builtin skills 从 enabled plugin skill contributions 派生。
   - workspace/project skill scan 保持原路径，直到 workspace plugin skill contribution 落地。
5. Command catalog
   - commands 从 core + plugin contributions 派生。
   - `/stop`、`/status`、`/new` 先保留 core contribution。

每迁移一条 catalog，都要删除对应旧硬编码主线，不保留旧列表作为备用入口。

### 实施注意事项

- Catalog consumer 不直接扫描 plugin 目录，只消费 `Plugin.Catalog` 或 runtime snapshot 投影。
- `Runtime.reload/1` 发布 snapshot 前，必须完成所有 catalog 输入准备。
- Tool execution 仍只走 `Tool.Registry.execute/3`。
- Tool definitions 和 execution map 必须同源；禁止只隐藏 definition、不更新 execute map。
- Provider request 仍只走 `ProviderProfile` facade。
- Provider availability diagnostics 归 `Config` / runtime projection 所有；provider adapter 不自己读取 plugin/config 文件。
- Channel config validation 仍只走 `Channel.Spec`。
- Skill prompt 仍只显示 card，不显示 body/path/source。
- Workbench config panel 的 channel/provider/tool capability metadata 必须从同一 contribution 派生。

### 本 stage 验收

- 禁用 `builtin:channel.discord` 后，Discord channel type 不出现在 catalog/config panel，Discord channel runtime 进入 diagnostics。
- 禁用一个 provider plugin 后，对应 provider type 不在 known providers 中，已有 config 产生可操作 diagnostics。
- 禁用一个 optional tool plugin 后，该 tool 不出现在 `definitions_all` / surfaces。
- 禁用一个 optional tool plugin 后，`Tool.Registry.execute/3` 对该 tool 返回 unknown tool。
- 禁用一个 provider plugin 后，Runner 不会使用引用该 provider 的 model runtime。
- unknown provider type 保留 raw type 并产生 diagnostics，不被规范化为 `:openai`。
- 核心 run-control tools 和最小 file/code maintenance tools 仍可用。
- `snapshot.plugins.hash` 变化会导致 runtime version 变化。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/plugin test/nex/agent/runtime_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/channel_spec_test.exs test/nex/agent/config_test.exs test/nex/agent/context_builder_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/llm/provider_registry_test.exs test/nex/agent/llm/provider_profile_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs test/nex/agent/runner_stream_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/skills_test.exs test/nex/agent/workbench/server_test.exs
/Users/krisxin/.local/bin/mise exec -- mix compile --warnings-as-errors
```

## Stage 3

### 前置检查

- Stage 2 catalog-derived tests 通过。
- 禁用 plugin 的 runtime reload / reconcile 行为已覆盖。
- Workbench config/diagnostics 能显示 plugin contribution 来源。

### 这一步改哪里

- `priv/plugins/builtin/channel.feishu/nex.plugin.json`
- `priv/plugins/builtin/channel.discord/nex.plugin.json`
- `priv/plugins/builtin/provider.anthropic/nex.plugin.json`
- `priv/plugins/builtin/provider.openai/nex.plugin.json`
- `priv/plugins/builtin/provider.openai-compatible/nex.plugin.json`
- `priv/plugins/builtin/provider.openrouter/nex.plugin.json`
- `priv/plugins/builtin/provider.ollama/nex.plugin.json`
- `priv/plugins/builtin/provider.openai-codex/nex.plugin.json`
- `priv/plugins/builtin/provider.openai-codex-custom/nex.plugin.json`
- `priv/plugins/builtin/tool.web/nex.plugin.json`
- `priv/plugins/builtin/tool.image-generation/nex.plugin.json`
- `priv/plugins/builtin/tool.memory/nex.plugin.json`
- `priv/plugins/builtin/tool.evolution/nex.plugin.json`
- `priv/plugins/builtin/tool.advisor/nex.plugin.json`
- `priv/plugins/builtin/tool.cron/nex.plugin.json`
- `priv/plugins/builtin/skill.nex-code-maintenance/nex.plugin.json`
- `priv/plugins/builtin/skill.runtime-observability/nex.plugin.json`
- `priv/plugins/builtin/skill.memory-and-evolution-routing/nex.plugin.json`
- `priv/plugins/builtin/skill.lark-feishu-ops/nex.plugin.json`
- `priv/plugins/builtin/skill.workbench-app-authoring/nex.plugin.json`
- `lib/nex/agent/channel/{catalog,registry,spec}.ex`
- `priv/plugins/builtin/channel.*/lib/**`
- `lib/nex/agent/llm/providers/{default,helpers}.ex`
- `priv/plugins/builtin/provider.*/lib/**`
- `lib/nex/agent/tool/**`
- `priv/plugins/builtin/tool.*/lib/**`
- `priv/plugins/builtin/skill.*/skills/**`
- `test/nex/agent/plugin/**`
- affected channel/provider/tool/skill/workbench tests

### 这一步要做

把非核心能力物理组织成 builtin plugins。

第一批迁移顺序：

1. Provider plugins
   - 迁移风险最低，主要是 adapter registration。
2. Builtin skill plugins
   - SKILL.md 仍保留原正文，plugin manifest 只声明 ownership。
3. Optional tool family plugins
   - web/image/advisor/cron/evolution/memory。
4. Channel plugins
   - Feishu/Discord 最后迁移，因为涉及 Gateway reconnect、IM renderer、Workbench config。

目录迁移时每一批必须同时更新：

- plugin manifest
- catalog contribution tests
- affected runtime snapshot assertions
- Workbench config/diagnostic projection
- onboarding / docs references if paths or ids changed

### 实施注意事项

- 不改用户可见 channel config shape，除非另开 config phase。
- 不改 provider external config provider type names。
- 不改 tool model-visible names。
- 不改 skill ids，除非 tests 和 docs 明确同步。
- 不把 Feishu/Discord 协议细节泄漏到 generic plugin host。
- 不把 provider-native tool lane 借插件系统重新引入。
- 不因为模块移动而保留旧 alias 或旧备用分支。

### 本 stage 验收

- Feishu/Discord/provider/tool/skill 的 owner plugin id 可从 runtime snapshot 查到。
- 禁用 optional plugin 后，对应能力从 prompt/tool/channel/provider/workbench projection 消失。
- 禁用 channel plugin 后 Gateway reconcile 停止相关 channel child。
- 禁用 provider plugin 后对应 model config 产生 diagnostics，Runner 不使用该 provider。
- 禁用 skill plugin 后对应 skill card 不进 prompt，`skill_get` 返回 not found。
- 禁用 tool plugin 后对应 tool 不在 LLM definitions 中，直接执行返回 unknown tool。
- 所有迁移后的 tests 不再断言旧硬编码列表。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/plugin
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/runtime_test.exs test/nex/agent/runtime_reconciler_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/channel_spec_test.exs test/nex/agent/channel_feishu_test.exs test/nex/agent/channel_discord_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/llm
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/tool_alignment_test.exs test/nex/agent/runner_stream_test.exs test/nex/agent/inbound_worker_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/skills_test.exs test/nex/agent/context_builder_test.exs
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/workbench
/Users/krisxin/.local/bin/mise exec -- mix compile --warnings-as-errors
/Users/krisxin/.local/bin/mise exec -- mix test
```

## Review Fail 条件

- 任一 consumer 直接扫描 plugin 目录，而不是通过 plugin catalog/runtime snapshot。
- 插件启停只在冷启动生效，runtime reload 后长期进程仍使用旧能力。
- 同一能力同时存在 hardcoded list 和 plugin contribution 两个 truth source。
- 禁用 plugin 后 prompt、tool definitions、Workbench config、Gateway reconcile、provider registry 中仍残留该能力。
- Workspace/project plugin 可以动态加载任意 Elixir code。
- Plugin manifest 变化没有被 `Runtime.Watcher` 纳入 reload 触发面。
- Provider type 在 plugin 不可用时被静默规范化成其他 provider。
- Tool definitions 和 `Tool.Registry.execute/3` 使用不同来源，导致 hidden tool 仍可直接执行。
- Phase 20 接受了 `workbench_apps`、`workbench_views` 或 `subagents` active contribution 但没有对应 consumer tests。
- Workspace/project command plugin 可以声明 executable handler。
- Tool execution 出现绕过 `Tool.Registry` 的新路径。
- Provider adapter 绕过 `ProviderProfile` / `ReqLLM` facade。
- Channel plugin 绕过 `Channel.Spec` / `Channel.Catalog`。
- Skill plugin 绕过 `Skills.Catalog` / `skill_get` progressive disclosure。
- Workbench plugin 绕过 manifest declaration、permissions grant 或 bridge enforcement。
- Plugin diagnostics 包含 secrets、raw tokens、完整 prompt、完整 tool result。
- 文档仍描述旧 hardcoded registry 为唯一入口。
