# Phase 19 Channel Spec Registry And Prompt Governance

## 当前状态

当前 channel 相关真相源分散在多处：

- `Nex.Agent.Runtime.Config` 知道 channel type、默认 streaming、Discord `show_table_as` 规范化。
- `Nex.Agent.Interface.Gateway` 通过私有分支把 channel type 映射到 channel GenServer module。
- `Nex.Agent.Turn.ContextBuilder` 同时硬编码全局 channel output rules 和 per-channel runtime prompt。
- `Nex.Agent.Interface.IMIR` 通过私有分支选择 Feishu / Discord parser profile。
- `Nex.Agent.Interface.IMIR.Renderers.*` 和 channel module 各自知道如何渲染或发送。
- `Nex.Agent.Runtime.Snapshot.channels` 只是 config runtime 投影，不知道 channel 的 prompt / renderer / gateway spec。

这导致新增或调整一个 channel 时，执行者必须在多个文件里人工同步同一件事。以 Discord 为例，格式 prompt 藏在 `ContextBuilder` 中，parser heading 能力藏在 `IMIR.Parser` 中，table mode 藏在 `Config` 和 renderer 中；reviewer 很难确认一个 channel 的完整 contract 是否一致。

本 phase 目标不是给 prompt 换一个文件位置，而是把 channel type 作为 CODE 层一等 spec 收口。每个内置 channel 必须通过统一 catalog 注册；Config、Gateway、prompt、IM IR 选择都从同一个 catalog 找 channel spec。

## 完成后必须达到的结果

Phase 19 结束时仓库必须满足：

1. 新增 `Nex.Agent.Interface.Channel.Spec` behaviour，冻结 channel spec 最小接口。
2. 新增 `Nex.Agent.Interface.Channel.Catalog`，作为内置 channel type 的唯一注册入口。
3. Feishu 和 Discord 都有独立 spec module，并且只通过 catalog 暴露给 Config / Gateway / ContextBuilder / IMIR。
4. `ContextBuilder` 不再硬编码 Discord / Feishu format prompt。
5. `ContextBuilder.build_runtime_context/3` 只输出 runtime metadata，不再混入 format 指令。
6. 当前 turn 的 channel format prompt 自动注入 system message；Discord format prompt 只在 Discord channel turn 出现。
7. Channel format prompt 允许手写，不强制从结构化 markdown capability DSL 生成。
8. `Config` 不再维护独立的 channel type allowlist、默认 streaming 分支、Discord table mode 分支；这些逻辑归 channel spec。
9. `Gateway` 不再维护独立的 channel type -> module 分支；该映射归 channel spec。
10. `IMIR.new/1` 不再维护 Feishu / Discord 私有分支；profile 选择归 channel spec 或 channel catalog。
11. `Workbench.ConfigPanel` 不再维护独立 channel type list、Discord table modes、channel type guide、默认 streaming、enabled secret contract；这些 UI / raw-config editing facts 从 channel spec 派生。
12. 删除旧的平行路径；不保留兼容垫片、fallback branch、legacy alias 或双主线。
13. 测试能证明新增 channel spec 是主入口：format prompt、runtime config、gateway module、IM profile、renderer、Workbench channel config metadata 都从 catalog 取。

## 开工前必须先看的代码路径

- `docs/dev/progress/CURRENT.md`
- `docs/dev/findings/2026-04-28-skill-progressive-disclosure-catalog.md`
- `docs/dev/task-plan/phase4-im-text-ir-and-renderers.md`
- `lib/nex/agent/config.ex`
- `lib/nex/agent/gateway.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent/workbench/config_panel.ex`
- `lib/nex/agent/im_ir.ex`
- `lib/nex/agent/im_ir/parser.ex`
- `lib/nex/agent/im_ir/profiles/discord.ex`
- `lib/nex/agent/im_ir/profiles/feishu.ex`
- `lib/nex/agent/im_ir/renderers/discord.ex`
- `lib/nex/agent/im_ir/renderers/feishu.ex`
- `lib/nex/agent/channel/discord.ex`
- `lib/nex/agent/channel/feishu.ex`
- `test/nex/agent/config_test.exs`
- `test/nex/agent/context_builder_test.exs`
- `test/nex/agent/runtime_test.exs`
- `test/nex/agent/workbench/server_test.exs`
- `test/nex/agent/im_ir/parser_test.exs`
- `test/nex/agent/im_ir/discord_renderer_test.exs`
- `test/nex/agent/im_ir/feishu_renderer_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

1. Channel catalog 是 channel type 的 CODE 层唯一注册入口。

```elixir
defmodule Nex.Agent.Interface.Channel.Catalog do
  @spec all() :: [module()]
  def all

  @spec fetch(String.t() | atom()) :: {:ok, module()} | {:error, {:unknown_channel_type, String.t()}}
  def fetch(type)

  @spec fetch!(String.t() | atom()) :: module()
  def fetch!(type)

  @spec types() :: [String.t()]
  def types
end
```

2. 第一版注册列表只包含已实现 channel。

```elixir
[
  Nex.Agent.Interface.Channel.Specs.Feishu,
  Nex.Agent.Interface.Channel.Specs.Discord
]
```

不得注册未完成的 Telegram / Slack / DingTalk placeholder。

3. Channel spec behaviour 最小接口冻结为：

```elixir
defmodule Nex.Agent.Interface.Channel.Spec do
  @type instance_config :: map()
  @type runtime_config :: map()
  @type diagnostic :: %{
          optional(:code) => atom(),
          optional(:field) => String.t(),
          optional(:instance_id) => String.t(),
          optional(:type) => String.t() | nil,
          optional(:message) => String.t()
        }

  @callback type() :: String.t()
  @callback gateway_module() :: module()
  @callback apply_defaults(instance_config()) :: instance_config()
  @callback validate_instance(instance_config(), keyword()) :: :ok | {:error, [diagnostic()]}
  @callback runtime(instance_config()) :: runtime_config()
  @callback format_prompt(runtime_config(), keyword()) :: String.t()
  @callback im_profile() :: map() | nil
  @callback renderer() :: module() | nil
  @callback config_contract() :: map()
end
```

4. Channel spec module naming 冻结为：

```text
lib/nex/agent/channel/spec.ex
lib/nex/agent/channel/catalog.ex
lib/nex/agent/channel/specs/feishu.ex
lib/nex/agent/channel/specs/discord.ex
```

Module names:

```elixir
Nex.Agent.Interface.Channel.Spec
Nex.Agent.Interface.Channel.Catalog
Nex.Agent.Interface.Channel.Specs.Feishu
Nex.Agent.Interface.Channel.Specs.Discord
```

5. `config_contract/0` 是 channel config / Workbench editing metadata 的真相源。

最小 shape 冻结为：

```elixir
%{
  "type" => String.t(),
  "label" => String.t(),
  "ui" => %{
    "summary" => String.t(),
    "requires" => [String.t()]
  },
  "fields" => [String.t()],
  "secret_fields" => [String.t()],
  "required_when_enabled" => [String.t()],
  "defaults" => map(),
  "options" => %{optional(String.t()) => [String.t()]}
}
```

Feishu 第一版：

```elixir
%{
  "type" => "feishu",
  "label" => "Feishu",
  "ui" => %{
    "summary" => "Feishu/Lark bot websocket channel.",
    "requires" => ["app_id", "app_secret or env var", "allow_from for access control"]
  },
  "fields" => [
    "type",
    "enabled",
    "streaming",
    "app_id",
    "app_secret",
    "encrypt_key",
    "verification_token",
    "allow_from"
  ],
  "secret_fields" => ["app_secret", "encrypt_key", "verification_token"],
  "required_when_enabled" => ["app_id", "app_secret"],
  "defaults" => %{"streaming" => true},
  "options" => %{}
}
```

Discord 第一版：

```elixir
%{
  "type" => "discord",
  "label" => "Discord",
  "ui" => %{
    "summary" => "Discord Gateway bot channel.",
    "requires" => ["bot token or env var", "optional guild_id", "allow_from for access control"]
  },
  "fields" => ["type", "enabled", "streaming", "token", "guild_id", "allow_from", "show_table_as"],
  "secret_fields" => ["token"],
  "required_when_enabled" => ["token"],
  "defaults" => %{"streaming" => false, "show_table_as" => "ascii"},
  "options" => %{"show_table_as" => ["raw", "ascii", "embed"]}
}
```

`Workbench.ConfigPanel` must derive:

- channel type list from `Channel.Catalog.types/0`
- channel type guide from `spec.config_contract/0`
- Discord table modes from `spec.config_contract()["options"]["show_table_as"]`
- default streaming from `spec.config_contract()["defaults"]["streaming"]`
- secret redaction / secret write protection from `spec.config_contract()["secret_fields"]`
- enabled-channel required fields from `spec.config_contract()["required_when_enabled"]`

It must not keep `@channel_types`, `@discord_table_modes`, or channel-specific enabled secret branches.

6. `format_prompt/2` 是手写 prompt 接口，不是 markdown capability DSL。

Allowed:

```elixir
def format_prompt(runtime, opts) do
  show_table_as = Map.get(runtime, "show_table_as", "ascii")

  """
  ## Discord Output Contract
  ...
  Markdown tables render as #{show_table_as}.
  """
  |> String.trim()
end
```

Not allowed:

```elixir
%{
  markdown: %{
    headings: 1..3,
    forbidden_line_prefixes: ["####"]
  }
}
```

Structured data may exist inside a spec only when needed for deterministic code paths, but it must not become a required prompt authoring DSL in this phase.

7. `runtime/1` must not expose secrets.

Allowed runtime map examples:

```elixir
%{"type" => "feishu", "streaming" => true}

%{
  "type" => "discord",
  "streaming" => false,
  "show_table_as" => "ascii"
}
```

Forbidden runtime keys:

```text
token
app_secret
api_key
authorization
password
```

8. Config / spec / Workbench secret boundary is frozen.

`Config` owns generic parsing and runtime secret resolution:

- stringifying map keys
- generic optional string normalization
- generic secret spec handling such as `%{"env" => "DISCORD_TOKEN"}`
- resolving env references to runtime secrets for actual channel processes

Channel specs own channel-specific policy only:

- defaults
- valid fields / options
- enabled-channel requirements
- runtime projection
- prompt text

Channel specs must not call:

```elixir
System.get_env/1
Config.load/0
Config.read_map/1
```

Channel specs must not duplicate a private `resolve_secret` implementation.

`Workbench.ConfigPanel` owns raw config editing and display:

- it preserves `%{"env" => "NAME"}` references in saved JSON
- it redacts every field listed in spec `secret_fields`
- it validates enabled-channel required fields using spec `required_when_enabled`
- for required secret fields, either a non-empty literal or non-empty `%{"env" => name}` counts as configured
- optional secret fields, such as Feishu `encrypt_key` and `verification_token`, are redacted and preserved but are not treated as enabled-channel requirements unless listed in `required_when_enabled`
- it must not resolve env vars for display or raw write-back

`Config.valid?/1` validates runtime-normalized readiness after generic secret resolution. If an enabled channel points at `%{"env" => "NAME"}` and that env var is missing in the current OS process, runtime readiness may be false.

`Workbench.ConfigPanel` raw save validation is different:

- it validates raw JSON shape through catalog/spec metadata
- it accepts non-empty env references as configured secrets without resolving them
- it rejects unknown channel types before save
- it may still report runtime reload failure separately if the current process cannot resolve an env reference

Do not use runtime secret availability as the sole authority for whether Workbench may save a raw env-reference config.

After a raw-valid Workbench save succeeds, the file is durable desired config. Runtime reload is an activation attempt:

```elixir
%{
  "runtime_reload" => %{
    "status" => "failed",
    "applied" => false,
    "reason" => String.t()
  }
}
```

If runtime reload fails because the current process cannot resolve an env reference, Workbench must not roll the raw file back. The active `Runtime.Snapshot` remains the previous applied snapshot until a later reload succeeds, and the response must clearly report that the saved config is not active yet.

The old Phase 18 test expectation "runtime reload failed; config rolled back" must be replaced for raw-valid config saves in this phase. Rollback is only for write failures that occur before a new raw file is durably saved.

9. Channel defaults, validation, and runtime projection are spec-owned while generic config traversal remains in `Config`.

Frozen behavior:

```elixir
@type channel_diagnostic :: %{
        required(:code) => atom(),
        required(:instance_id) => String.t(),
        required(:type) => String.t() | nil,
        optional(:field) => String.t(),
        required(:message) => String.t()
      }

@spec Config.channel_runtime(Config.t(), String.t() | atom()) ::
        {:ok, map()} | {:error, channel_diagnostic()}

@spec Config.channels_runtime(Config.t()) :: %{optional(String.t()) => map()}

@spec Config.channel_diagnostics(Config.t()) :: [channel_diagnostic()]
```

For a known valid channel, `Config.channel_runtime/2` must call:

```elixir
with %{} = instance <- Config.channel_instance(config, instance_id),
     {:ok, spec} <- Channel.Catalog.fetch(Map.get(instance, "type")),
     normalized <- spec.apply_defaults(instance),
     :ok <- spec.validate_instance(normalized, mode: :runtime),
     runtime <- spec.runtime(normalized) do
  {:ok, runtime}
end
```

For unknown or invalid channels, `Config.channel_runtime/2` must return `{:error, diagnostic}` and must not raise, match fail, or invent a generic runtime map.

`Config.channels_runtime/1` returns only successfully projected runtime entries. Invalid entries remain available through `Config.channel_instances/1` and are reported through `Config.channel_diagnostics/1`.

`Config.valid?/1` delegates to diagnostics:

```elixir
Config.channel_diagnostics(config) == []
```

as part of its full config validation.

`Config` may orchestrate config shape traversal, key stringification, generic secret resolution, and diagnostics aggregation, but it must not contain channel-specific logic such as:

```elixir
defp default_streaming(%{"type" => "feishu"}), do: true
defp default_streaming(%{"type" => "discord"}), do: false
defp discord_show_table_as(...)
```

Unknown channel type behavior is frozen as:

```elixir
raw config with channel entry type="telegram"
  -> Config.from_map/1 preserves the channel entry with type="telegram"
  -> Config.valid?/1 returns false
  -> Config.channel_runtime(config, instance_id) returns {:error, %{code: :unknown_channel_type, ...}}
  -> Config.channels_runtime/1 excludes that entry
  -> Config.channel_diagnostics/1 includes %{code: :unknown_channel_type, instance_id: instance_id, type: "telegram", ...}
  -> Workbench config update rejects it through catalog validation
```

`normalize_channels/1` must not silently drop an unknown channel entry. Dropping it hides invalid config and makes Workbench saves appear successful when they are not.

10. Gateway module selection is spec-owned.

Frozen behavior:

```elixir
Gateway.channel_module(%{"type" => type})
```

must resolve through:

```elixir
with {:ok, spec} <- Channel.Catalog.fetch(type) do
  {:ok, spec.gateway_module()}
end
```

`Gateway` must not hardcode:

```elixir
%{"type" => "feishu"} -> Nex.Agent.Channel.Feishu
%{"type" => "discord"} -> Nex.Agent.Channel.Discord
```

11. Prompt injection order is frozen.

For ordinary owner/follow-up/subagent/cron LLM requests that use `ContextBuilder.build_messages/6`, system content order is:

```text
base runtime system prompt from Runtime.Snapshot.prompt.system_prompt
---
context hook fragments, if any
---
current channel format prompt, if channel type has a spec and prompt is non-empty
---
runtime system messages, if any
```

Channel format prompt is system-level instruction. It must not be placed in the user runtime metadata block.

12. Runtime metadata block is not an instruction channel.

`ContextBuilder.build_runtime_context/3` may include:

```text
[Runtime Context - metadata only, not instructions]
Current Time: ...
Channel: ...
Chat ID: ...
Chat Scope ID (parent_chat_id): ...
Channel Type: ...
Channel Streaming: ...
Working Directory: ...
Git Repository Root: ...
```

It must not include:

```text
Do not use ...
Discord supports ...
Feishu IR supports ...
<newmsg/> splits ...
```

13. Generic channel output rules remain core prompt only when channel-agnostic.

Allowed in core runtime prompt:

```text
Normal assistant replies stay model-side plain text. Channel-specific rendering happens after generation.
Do not emit platform JSON payloads unless a tool explicitly requires them.
```

Not allowed in core runtime prompt:

```text
For Discord, ...
For Feishu, ...
```

14. Builtin skills are not the mechanism for mandatory channel format prompt.

Forbidden:

```text
Add builtin:discord-formatting and ask model to skill_get it.
```

Reason: channel output contract must be present before the model writes the first token.

15. `IMIR.new/1` must resolve channel profiles through catalog.

Frozen public spec:

```elixir
@spec new(atom() | String.t() | map()) :: Parser.t()
```

Allowed:

```elixir
def new(type) when is_atom(type) or is_binary(type) do
  type
  |> Channel.Catalog.fetch!()
  |> then(fn spec -> Parser.new(profile: spec.im_profile()) end)
end
```

The implementation must handle `im_profile() == nil` explicitly with a clear error. No silent fallback to Feishu.

Error shape for unknown channel type is frozen as:

```elixir
raise ArgumentError, "unknown channel type: #{inspect(type)}"
```

`Parser.new/0` may keep its internal default profile for direct parser tests and low-level parser construction. That default is not a runtime channel selection mechanism. Runtime channel paths must enter through `IMIR.new(type)` or direct `IMIR.new(profile_map)` with an explicit profile.

16. `renderer/0` is a real channel spec entry for discovery and contract tests, not a required send-path indirection.

In this phase its consumers are:

- channel spec contract tests
- generic channel discovery/debug views that need to show renderer module

Concrete channel modules may directly alias and call their platform renderer because they are the platform implementation boundary. Forcing `Nex.Agent.Channel.Discord` to ask the catalog which renderer Discord uses is self-referential indirection and is not required.

This phase does not require a common renderer behaviour because Discord and Feishu renderer functions have different platform-specific APIs. It does require that the concrete renderer module is discoverable from channel spec and that no second generic renderer registry is introduced.

17. No compatibility branch.

This phase intentionally removes old local branch logic. Do not keep:

- duplicate type allowlists in `Config`
- duplicate type -> module maps in `Gateway`
- duplicate format prompt strings in `ContextBuilder`
- `IMIR.new(:discord)` / `IMIR.new(:feishu)` private heads after catalog cutover
- fallback prompt for old channel types

18. Tests are contract tests, not snapshot-only string tests.

Each channel spec must have tests for:

- type registration
- runtime projection
- gateway module
- format prompt presence
- IM profile availability
- renderer module availability
- config contract availability, including default streaming, option fields, secret fields, and enabled requirements

Prompt tests must assert both presence and absence:

- Discord turn includes Discord format prompt in system content.
- Feishu turn includes Feishu format prompt in system content.
- Telegram/unknown channel does not get Discord/Feishu format prompt.
- Runtime metadata block does not contain format instructions.
- Workbench overview exposes channel type list / guides / table modes from channel specs.
- Unknown channel type is preserved as invalid and covered by a contract test.

## 执行顺序 / stage 依赖

- Stage 1: Add channel spec behaviour and catalog.
- Stage 2: Move channel config runtime and gateway module selection to specs.
- Stage 3: Move channel format prompt injection to specs.
- Stage 4: Move IM IR profile / renderer discovery to specs.
- Stage 5: Delete old prompt/config/IMIR branches and update docs/tests.

Stage 2 depends on Stage 1.  
Stage 3 depends on Stage 1 and Stage 2.  
Stage 4 depends on Stage 1.  
Stage 5 depends on Stages 2, 3, and 4.

## Stage 1

### 前置检查

- Confirm current worktree changes are understood before editing.
- Read `lib/nex/agent/channel/discord.ex` and `lib/nex/agent/channel/feishu.ex` enough to confirm gateway modules.
- Read current `Config.channel_runtime/2` and `Gateway.channel_module/1` implementations.

### 这一步改哪里

- Add `lib/nex/agent/channel/spec.ex`
- Add `lib/nex/agent/channel/catalog.ex`
- Add `lib/nex/agent/channel/specs/feishu.ex`
- Add `lib/nex/agent/channel/specs/discord.ex`
- Add `test/nex/agent/channel_spec_test.exs`

### 这一步要做

- Define `Nex.Agent.Interface.Channel.Spec` behaviour exactly as frozen above.
- Implement `Nex.Agent.Interface.Channel.Catalog` with a static list of Feishu and Discord specs.
- Implement Feishu spec:
  - `type/0` returns `"feishu"`.
  - `gateway_module/0` returns `Nex.Agent.Channel.Feishu`.
  - `config_contract/0` returns the frozen Feishu contract.
  - `apply_defaults/1` applies Feishu default streaming.
  - `validate_instance/2` enforces enabled Feishu requires `app_id` and `app_secret`.
  - `runtime/1` returns only non-secret runtime keys.
  - `format_prompt/2` returns hand-written Feishu output contract.
  - `im_profile/0` returns `Nex.Agent.Interface.IMIR.Profiles.Feishu.profile()`.
  - `renderer/0` returns `Nex.Agent.Interface.IMIR.Renderers.Feishu`.
- Implement Discord spec:
  - `type/0` returns `"discord"`.
  - `gateway_module/0` returns `Nex.Agent.Channel.Discord`.
  - `config_contract/0` returns the frozen Discord contract.
  - `apply_defaults/1` applies Discord default streaming and `show_table_as` normalization.
  - `validate_instance/2` enforces enabled Discord requires `token`.
  - `runtime/1` returns only non-secret runtime keys.
  - `format_prompt/2` returns hand-written Discord output contract, including no h4/h5/h6 and bold standalone labels.
  - `im_profile/0` returns `Nex.Agent.Interface.IMIR.Profiles.Discord.profile()`.
  - `renderer/0` returns `Nex.Agent.Interface.IMIR.Renderers.Discord`.

### 实施注意事项

- Do not wire callers yet except tests; this stage establishes the target contract.
- Do not add placeholder specs for channels not currently implemented.
- Do not create a DSL for markdown capabilities.
- Keep prompt text in spec modules short and direct.

### 本 stage 验收

- `Channel.Catalog.types()` returns exactly `["feishu", "discord"]` sorted or in registered order.
- `Channel.Catalog.fetch!("discord").format_prompt/2` returns the Discord format guidance.
- Runtime maps produced by specs contain no secret keys.
- Feishu and Discord specs expose gateway, renderer, and IM profile.
- Feishu and Discord specs expose config contract metadata used by Workbench.

### 本 stage 验证

```bash
mix test test/nex/agent/channel_spec_test.exs
```

## Stage 2

### 前置检查

- Stage 1 tests pass.
- `Config` tests are green before migration or failures are understood.

### 这一步改哪里

- Update `lib/nex/agent/config.ex`
- Update `lib/nex/agent/gateway.ex`
- Update `lib/nex/agent/workbench/config_panel.ex`
- Update `test/nex/agent/config_test.exs`
- Update `test/nex/agent/workbench/server_test.exs`
- Update or add focused gateway/catalog tests if existing coverage does not exercise module selection.

### 这一步要做

- Replace Config channel type validation with `Channel.Catalog.fetch/1`.
- Replace channel default application with `spec.apply_defaults/1`.
- Replace channel validation with `spec.validate_instance/2` diagnostics.
- Replace `Config.channel_runtime/2` channel-specific construction with `{:ok, spec.runtime(instance)} | {:error, diagnostic}`.
- Add `Config.channel_diagnostics/1` and make unknown channel diagnostics explicit.
- Delete `default_streaming/1` and Discord table mode helpers from `Config` after moving them into specs.
- Replace `Gateway.channel_module/1` type branches with catalog lookup that returns an explicit error for unknown types.
- Replace Workbench ConfigPanel channel type list and channel type guide with catalog/spec contract lookup.
- Replace Workbench ConfigPanel Discord table mode list with `spec.config_contract()["options"]["show_table_as"]`.
- Replace Workbench ConfigPanel default streaming with `spec.config_contract()["defaults"]["streaming"]`.
- Replace Workbench ConfigPanel secret redaction with generic contract-driven handling over `secret_fields`.
- Replace Workbench ConfigPanel enabled-channel validation with generic contract-driven validation over `required_when_enabled`.
- Replace Workbench ConfigPanel `validate_runtime_config/1` usage with raw config validation for save authority, then keep runtime reload status as a separate result signal.
- Change Workbench reload-failure behavior for raw-valid saves: preserve the saved raw file, keep active runtime on the previous snapshot, and return `runtime_reload.status = "failed"` with `applied = false`.
- Add unknown channel type contract coverage:
  - `Config.from_map/1` preserves the invalid entry.
  - `Config.valid?/1` returns false.
  - `Config.channel_runtime/2` returns `{:error, diagnostic}`.
  - `Config.channels_runtime/1` excludes invalid entries.
  - `Config.channel_diagnostics/1` reports the unknown type.
  - Workbench upsert rejects the unknown type.
- Keep config external shape unchanged:

```json
{
  "channel": {
    "discord_main": {
      "type": "discord",
      "enabled": true,
      "token": "...",
      "show_table_as": "ascii"
    }
  }
}
```

### 实施注意事项

- Do not preserve old Config helper branches as fallback.
- Do not add a second channel registry. `Nex.Agent.Interface.Channel.Registry` remains runtime instance/pid registry; `Nex.Agent.Interface.Channel.Catalog` is type/spec catalog.
- Config must not leak secrets into `channels_runtime`.
- Unknown channel type should be invalid config, not silently treated as plain text.
- Workbench raw config views must preserve env references and keep secret redaction behavior.
- Workbench save validation must not require the env var to be present in the current process when a raw `%{"env" => name}` reference is configured.
- Workbench must not treat optional secret fields as enabled-channel requirements.
- Workbench must not roll back a raw-valid save solely because runtime reload cannot resolve an env reference in the current process.
- Do not move generic secret resolution into channel specs.

### 本 stage 验收

- Config tests still prove Feishu defaults to streaming true and Discord defaults to streaming false.
- Discord `show_table_as` still normalizes to `raw | ascii | embed`.
- `Config.channel_runtime/2` returns `{:ok, runtime}` for valid Feishu / Discord entries and `{:error, diagnostic}` for unknown or invalid entries.
- `Config.channels_runtime/1` output is produced through specs and excludes invalid entries.
- `Config.channel_diagnostics/1` reports unknown channel types and missing enabled-channel requirements.
- Gateway resolves Feishu / Discord modules through specs.
- Workbench ConfigPanel derives channel types, guides, table modes, defaults, secret fields, and enabled requirements from specs.
- Workbench persists a raw-valid env-reference config even when the current runtime cannot activate it, and returns a failed reload status without rolling the file back.
- Unknown channel type is not silently dropped.
- Grep confirms no type -> module branch remains in `Gateway`.

### 本 stage 验证

```bash
mix test test/nex/agent/config_test.exs test/nex/agent/runtime_reconciler_test.exs test/nex/agent/workbench/server_test.exs
mix test test/nex/agent/channel_spec_test.exs
```

## Stage 3

### 前置检查

- Stage 2 tests pass.
- Read `ContextBuilder.build_system_prompt_with_diagnostics/1`, `build_runtime_context/3`, and `build_messages/6`.
- Confirm how `Runner` passes runtime snapshot config into `ContextBuilder`.

### 这一步改哪里

- Update `lib/nex/agent/context_builder.ex`
- Update `test/nex/agent/context_builder_test.exs`
- Update related runner/context-window tests if message shape assertions need adjustment.

### 这一步要做

- Delete Discord / Feishu specific prompt text from core runtime guidance.
- Keep only channel-agnostic output rules in the steady system prompt.
- Add a private or public `channel_format_prompt(channel, config, opts)` helper that:
  - resolves channel runtime through `Config.channel_runtime/2`
  - returns `""` for `{:error, _diagnostic}`
  - resolves spec through `Channel.Catalog.fetch/1` using the successful runtime type
  - calls `spec.format_prompt(runtime, opts)`
  - returns `""` if no channel is present
  - returns `""` if channel runtime has no valid type or no spec
- Inject the current channel format prompt into system content, not user content.
- Remove format instructions from `build_runtime_context/3`.
- Add metadata-only lines:

```text
Channel Type: discord
Channel Streaming: single
```

when config and channel runtime are available.

### 实施注意事项

- Do not ask the model to load a skill for channel formatting.
- Do not keep global Discord prompt in base system prompt.
- Do not put channel format instructions inside `[Runtime Context - metadata only, not instructions]`.
- Do not use runtime metadata as a hidden instruction lane.
- If channel type cannot be resolved, do not silently inject Feishu/Discord guidance.

### 本 stage 验收

- Discord `build_messages/6` system message contains `## Discord Output Contract`.
- Discord `build_messages/6` user message does not contain Discord format instructions.
- Feishu `build_messages/6` system message contains `## Feishu Output Contract`.
- Non-channel or unknown-channel calls do not contain Discord/Feishu format prompt.
- `build_system_prompt/1` steady prompt does not contain `For Discord` or `Feishu IR supports`.
- The existing skill catalog injection remains unchanged.

### 本 stage 验证

```bash
mix test test/nex/agent/context_builder_test.exs
mix test test/nex/agent/runner_stream_test.exs
```

## Stage 4

### 前置检查

- Stage 1 tests pass.
- Read `IMIR.new/1`, parser profile modules, and renderer tests.

### 这一步改哪里

- Update `lib/nex/agent/im_ir.ex`
- Update `lib/nex/agent/im_ir/profiles/discord.ex` only if needed for profile shape clarity.
- Update `lib/nex/agent/im_ir/profiles/feishu.ex` only if needed for profile shape clarity.
- Update `test/nex/agent/im_ir/parser_test.exs`
- Update `test/nex/agent/im_ir/discord_renderer_test.exs`
- Update `test/nex/agent/im_ir/feishu_renderer_test.exs`
- Update `test/nex/agent/channel_spec_test.exs`

### 这一步要做

- Replace private `IMIR.new(:discord)` / `IMIR.new(:feishu)` branches with catalog lookup.
- Preserve `IMIR.new(profile_map)` for direct parser tests and internal parser construction.
- If a spec has `im_profile() == nil`, return or raise a clear unsupported-channel error.
- Add tests that prove `IMIR.new(:discord)` and `IMIR.new("discord")` both use the Discord spec profile.
- Add tests that prove registered specs expose renderer modules.

### 实施注意事项

- Do not silently fall back to Feishu profile for unknown channel type.
- Do not move parser implementation into channel spec.
- Do not make renderer modules depend on prompt modules.
- Do not introduce a common renderer behaviour in this phase.
- Do not introduce a second generic renderer registry outside channel specs.
- Do not force concrete channel modules to fetch their own renderer through catalog unless that code is already generic and benefits from discovery.

### 本 stage 验收

- `IMIR.new(:discord)` still works through catalog.
- Unknown channel type produces a clear failure.
- Parser and renderer tests continue to pass.
- Grep confirms `IMIR` has no hardcoded Feishu/Discord function heads.
- Channel spec tests prove renderer discovery points at the same concrete renderer modules used by channel implementations.

### 本 stage 验证

```bash
mix test test/nex/agent/im_ir/parser_test.exs test/nex/agent/im_ir/discord_renderer_test.exs test/nex/agent/im_ir/feishu_renderer_test.exs
mix test test/nex/agent/channel_spec_test.exs
```

## Stage 5

### 前置检查

- Stages 2, 3, and 4 tests pass.
- Run grep for old hardcoded prompt/config branches and inspect every hit.

### 这一步改哪里

- Update `docs/dev/progress/CURRENT.md`
- Update `docs/dev/task-plan/index.md` if not already updated.
- Update any tests whose assertions still describe prompt hardcoding in `ContextBuilder`.
- Remove obsolete code from:
  - `lib/nex/agent/context_builder.ex`
  - `lib/nex/agent/config.ex`
  - `lib/nex/agent/gateway.ex`
  - `lib/nex/agent/workbench/config_panel.ex`
  - `lib/nex/agent/im_ir.ex`

### 这一步要做

- Delete old channel prompt strings from `ContextBuilder`.
- Delete old channel config helper branches from `Config`.
- Delete old gateway module branch from `Gateway`.
- Delete old Workbench channel type/table/default/secret branches from `ConfigPanel`.
- Delete old IMIR channel heads.
- Add grep-oriented tests or assertions where practical.
- Update `CURRENT.md` with the new channel spec registry contract.

### 实施注意事项

- Do not mark the phase complete while any old branch remains as a fallback.
- Do not leave comments that describe the deleted old path as available.
- Do not update docs to imply dynamic third-party channel plugins exist; this phase only governs built-in channel specs.
- Do not introduce runtime hot-loading of channel specs in this phase.

### 本 stage 验收

- The only Feishu/Discord specific format prompt text lives under `lib/nex/agent/channel/specs/`.
- The only built-in channel type registration list lives in `Nex.Agent.Interface.Channel.Catalog`.
- `ContextBuilder` only orchestrates prompt assembly and no longer owns platform-specific format copy.
- `Config` uses catalog/spec for channel type behavior.
- `Workbench.ConfigPanel` uses catalog/spec for channel type behavior and raw config editing metadata.
- `Gateway` uses catalog/spec for channel module resolution.
- Runtime prompt and per-turn prompt behavior are documented.

### 本 stage 验证

```bash
mix format lib/nex/agent/channel lib/nex/agent/config.ex lib/nex/agent/gateway.ex lib/nex/agent/workbench/config_panel.ex lib/nex/agent/context_builder.ex lib/nex/agent/im_ir.ex test/nex/agent
mix test test/nex/agent/channel_spec_test.exs test/nex/agent/config_test.exs test/nex/agent/context_builder_test.exs test/nex/agent/runtime_test.exs test/nex/agent/workbench/server_test.exs
mix test test/nex/agent/im_ir/parser_test.exs test/nex/agent/im_ir/discord_renderer_test.exs test/nex/agent/im_ir/feishu_renderer_test.exs
mix test test/nex/agent/channel_discord_test.exs test/nex/agent/channel_feishu_test.exs test/nex/agent/inbound_worker_test.exs
```

Manual grep checks:

```bash
rg -n "For Discord|Feishu IR supports|Discord supports|@channel_types|@discord_table_modes|show_table_as|default_streaming|channel_module\\(" lib/nex/agent
```

Every hit must be either:

- inside a channel spec,
- inside a channel implementation,
- inside a renderer/parser implementation,
- inside a test intentionally asserting the new contract.

## Review Fail 条件

- `ContextBuilder` still contains Discord or Feishu format prompt text.
- The short-term Discord `####` hardening prompt remains in `ContextBuilder` instead of being moved into Discord channel spec prompt.
- `ContextBuilder.build_runtime_context/3` still emits instructions under the metadata tag.
- `Config` still has channel type-specific normalization branches outside specs.
- `Workbench.ConfigPanel` still has channel type-specific lists, guides, table modes, defaults, or enabled secret branches outside specs.
- `Gateway` still hardcodes channel type -> module mapping outside specs.
- `IMIR.new/1` still has direct `:discord` / `:feishu` branches.
- Unknown channel type is dropped during normalization instead of preserved as invalid.
- `Config.channel_runtime/2` raises, match fails, or returns a fake runtime map for unknown channel types instead of `{:error, diagnostic}`.
- `Config.channels_runtime/1` includes invalid unknown channel entries.
- Channel specs resolve env secrets or duplicate Config secret resolution.
- Workbench resolves env secrets for display or raw write-back instead of preserving env references.
- Workbench uses `secret_fields` as enabled-channel requirements instead of using `required_when_enabled`.
- Optional secret fields are not redacted or are accidentally made required.
- Workbench rolls back a raw-valid save solely because runtime reload cannot resolve an env reference in the current process.
- `renderer/0` exists but is not covered by contract tests or disagrees with the concrete renderer module used by the channel implementation.
- A builtin skill is introduced for mandatory Discord/Feishu formatting.
- Channel format prompt is injected only after the model chooses to load something.
- Unknown channel type silently degrades to Feishu, Discord, or generic markdown without config invalidation.
- Secret config fields appear in runtime channel maps or prompt text.
- Tests only check positive prompt presence and do not check absence from non-matching channels.
- The phase leaves compatibility wrappers, alias APIs, fallback branches, or comments promising old behavior.
