# Phase 12 LLM Provider Adapter Architecture

## 当前状态

当前 LLM provider 差异分散在三处：

- `lib/nex/agent/llm/provider_profile.ex` 同时负责 provider 归一化、base_url、auth mode、auth token、message/options 改写、provider_options、model_spec。
- `lib/nex/agent/llm/req_llm.ex` 是主调用链，但仍直接选择 provider-specific stream function。
- `lib/nex/agent/llm/openai_codex_stream.ex` 和 `lib/nex/agent/llm/openai_codex_responses_policy.ex` 已经把 ChatGPT Codex backend 的差异收口，但它们还没有进入统一 provider adapter 架构。

这导致新增 provider 时容易继续在 `ProviderProfile` / `ReqLLM` 中加分支，provider 间不是独立可插拔模块。

## 完成后必须达到的结果

Phase 12 完成时仓库必须满足：

1. `ReqLLM` 主链不包含任何具体 provider 模块名，也不按 provider 分支选择 stream/client/payload policy。
2. 每个已知 provider 至少有一个独立 adapter 模块：
   - `:anthropic`
   - `:openrouter`
   - `:ollama`
   - `:openai_codex`
   - `:openai_codex_custom`
3. `ProviderProfile` 只保留 profile struct、公共 accessor/facade 和 registry dispatch，不再承载 provider-specific policy 实现。
4. `openai-codex` OAuth 的当前可用行为保持不变：
   - config provider 仍是 `"openai-codex"`
   - standard OAuth base URL 仍走 ChatGPT Codex backend
   - third-party codex-compatible base URL 仍走 API key path
   - 请求体仍包含顶层 `instructions`
   - 请求体仍强制 `store: false`
   - 请求体仍不发送 `previous_response_id`
   - 请求体仍不发送 `max_output_tokens`
   - reasoning replay item 仍不发送 `id`
5. 新增 provider 的最小接入路径是新增一个 adapter 模块并在 registry 注册；不需要改 `ReqLLM` 主链。
6. 所有 provider adapter contract 有 focused tests，覆盖 profile、auth、model_spec、stream fun 选择、provider_options、message/options 改写。

## 开工前必须先看的代码路径

- `lib/nex/agent/llm/req_llm.ex`
- `lib/nex/agent/llm/provider_profile.ex`
- `lib/nex/agent/llm/openai_codex_stream.ex`
- `lib/nex/agent/llm/openai_codex_responses_policy.ex`
- `test/nex/agent/llm/req_llm_test.exs`
- `lib/nex/agent/config.ex`
- `lib/nex/agent/auth/codex.ex`
- `deps/req_llm/lib/req_llm/providers/openai/responses_api.ex`

## 固定边界 / 已冻结的数据结构与 contract

1. 外部配置 contract 不变：

```json
{
  "model": "gpt-5.5",
  "provider": "openai-codex"
}
```

`Config.provider_to_atom/1` 的已有 provider 名称映射不能在本 phase 改名。

2. `Nex.Agent.Turn.LLM.ProviderProfile` 最小 shape 冻结为：

```elixir
%Nex.Agent.Turn.LLM.ProviderProfile{
  provider: atom(),
  resolved_provider: atom(),
  base_url: String.t() | nil,
  auth_mode: atom() | nil,
  adapter: module()
}
```

允许添加 `adapter` 字段；不允许删除前四个字段。

3. Provider adapter behavior 冻结为：

```elixir
@type stream_text_fun ::
        (ReqLLM.model_input(), ReqLLM.Context.prompt(), keyword() ->
           {:ok, ReqLLM.StreamResponse.t()} | {:error, term()})

@callback build_profile(keyword()) :: Nex.Agent.Turn.LLM.ProviderProfile.t()
@callback default_model() :: String.t()
@callback default_api_key() :: String.t() | nil
@callback default_base_url() :: String.t() | nil
@callback prepare_messages_and_options([map()], Nex.Agent.Turn.LLM.ProviderProfile.t(), keyword()) ::
            {[map()], keyword()}
@callback api_key_config(Nex.Agent.Turn.LLM.ProviderProfile.t(), keyword()) ::
            {String.t() | nil, boolean()}
@callback provider_options(Nex.Agent.Turn.LLM.ProviderProfile.t(), keyword()) :: keyword()
@callback model_spec(Nex.Agent.Turn.LLM.ProviderProfile.t(), String.t()) :: String.t() | map()
@callback stream_text_fun(Nex.Agent.Turn.LLM.ProviderProfile.t()) :: stream_text_fun()

@optional_callbacks default_model: 0,
                    default_api_key: 0,
                    default_base_url: 0,
                    prepare_messages_and_options: 3,
                    api_key_config: 2,
                    provider_options: 2,
                    model_spec: 2,
                    stream_text_fun: 1
```

Adapter 只实现与 default adapter 不同的 callbacks；不要为了满足 behavior 写空转发。

4. Registry contract 冻结为：

```elixir
@spec adapter_for(atom()) :: module()
@spec known_providers() :: [atom()]
```

Unknown provider 必须走 default adapter，不能 raise。

5. `ReqLLM` 主链冻结为只依赖 facade：

```elixir
profile = ProviderProfile.for(provider, options)
ProviderProfile.prepare_messages_and_options(messages, profile, options)
ProviderProfile.api_key_config(profile, options)
ProviderProfile.provider_options(profile, options)
ProviderProfile.default_model(profile)
ProviderProfile.model_spec(profile, model)
ProviderProfile.stream_text_fun(profile)
```

`ReqLLM` 中不允许出现 `OpenAICodex*`、`OpenRouter*`、`Ollama*` 等具体 provider module alias。

6. Provider adapter 不允许读取配置文件或 runtime 文件；只使用传入的 `options`、`System.get_env/1`、现有 auth resolver、现有 config/runtime facade。

7. 本 phase 不改 LLM response parsing、tool execution contract、channel behavior、memory consolidation contract。

## 执行顺序 / stage 依赖

- Stage 1：补齐当前行为 contract 测试，冻结迁移前行为。
- Stage 2：引入 adapter behavior、registry、default adapter，并让 `ProviderProfile` 通过 registry dispatch。
- Stage 3：迁移现有 provider 到独立 adapter 模块。
- Stage 4：把 OpenAI Codex stream/policy 移入 provider adapter 命名空间并补 provider-specific contract tests。
- Stage 5：删除旧分支、补文档和回归。

## Stage 1

### 前置检查

- 确认当前 `openai-codex` OAuth 可用修复已经存在。
- 确认 `test/nex/agent/llm/req_llm_test.exs` 已覆盖 `instructions`、`store: false`、`max_output_tokens` stripping、`previous_response_id` stripping。

### 这一步改哪里

- `test/nex/agent/llm/provider_profile_test.exs`
- `test/nex/agent/llm/req_llm_test.exs`

### 这一步要做

补 migration guard tests：

- `openai_codex` default profile:
  - `resolved_provider == :openai`
  - default base_url 是 ChatGPT Codex backend
  - auth_mode 是 `:oauth`
- `openai_codex` custom base URL:
  - auth_mode 是 `:api_key`
  - 不注入 `instructions` 到 provider_options
  - `system_prompt` 接收 system instructions
- `openai_codex_custom`:
  - 总是 `:api_key`
- `openrouter`:
  - 注入 app referer/title provider options
- `ollama`:
  - base_url 自动补 `/v1`
  - api key 使用 placeholder

### 实施注意事项

- 这一 stage 只补测试，不重构。
- 不跑 live API。
- 不读取 `~/.nex`。

### 本 stage 验收

- 当前行为被 tests 明确冻结。
- 后续 stage 如果改坏 provider 行为，会先在 focused tests 失败。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/llm/provider_profile_test.exs test/nex/agent/llm/req_llm_test.exs
```

如本机没有 mise path，可用 `/opt/homebrew/bin/mix` 跑同等命令。

## Stage 2

### 前置检查

- Stage 1 tests 通过。
- 确认没有在 `ReqLLM` 主链继续新增 provider-specific 分支。

### 这一步改哪里

- `lib/nex/agent/llm/provider_adapter.ex`
- `lib/nex/agent/llm/provider_registry.ex`
- `lib/nex/agent/llm/providers/default.ex`
- `lib/nex/agent/llm/provider_profile.ex`
- `test/nex/agent/llm/provider_registry_test.exs`
- `test/nex/agent/llm/provider_profile_test.exs`

### 这一步要做

新增 `ProviderAdapter` behavior 和 `ProviderRegistry`。

`ProviderProfile.for/2` 改为：

```elixir
adapter = ProviderRegistry.adapter_for(provider)
adapter.build_profile(options)
```

`ProviderProfile` 中已有 facade 函数改为委托给 `profile.adapter`：

```elixir
def prepare_messages_and_options(messages, %__MODULE__{adapter: adapter} = profile, options) do
  adapter.prepare_messages_and_options(messages, profile, options)
end
```

Default adapter 实现当前 generic provider 行为。

### 实施注意事项

- 不要在 registry 里读取用户配置。
- Registry 是静态 provider -> module 映射，不引入 runtime mutable state。
- Unknown provider 走 default adapter，保留当前宽松行为。

### 本 stage 验收

- `ProviderProfile` facade 可用。
- `ReqLLM` 调用点不需要知道 adapter module。
- 当前 tests 仍通过。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/llm/provider_registry_test.exs test/nex/agent/llm/provider_profile_test.exs test/nex/agent/llm/req_llm_test.exs
```

## Stage 3

### 前置检查

- Stage 2 tests 通过。
- `ProviderProfile` 已经可以通过 adapter dispatch。

### 这一步改哪里

- `lib/nex/agent/llm/providers/anthropic.ex`
- `lib/nex/agent/llm/providers/openrouter.ex`
- `lib/nex/agent/llm/providers/ollama.ex`
- `lib/nex/agent/llm/providers/openai_codex.ex`
- `lib/nex/agent/llm/providers/openai_codex_custom.ex`
- `lib/nex/agent/llm/provider_registry.ex`
- `lib/nex/agent/llm/provider_profile.ex`
- `test/nex/agent/llm/provider_profile_test.exs`

### 这一步要做

把 `ProviderProfile` 中已有 provider-specific 分支迁移到 provider modules：

- `OpenRouter` owns:
  - default base_url
  - app referer/title provider_options
- `Ollama` owns:
  - base_url `/v1` normalization
  - placeholder api key
  - resolved_provider `:openai`
- `OpenAICodex` owns:
  - default OAuth access token resolver
  - base_url/auth_mode decision
  - system instructions extraction for OAuth vs API key mode
  - provider_options auth mode/access token/instructions
  - stream_text_fun
- `OpenAICodexCustom` owns:
  - custom api key/base URL resolver
  - API key auth mode
  - system_prompt path
- `Anthropic` owns normal direct provider behavior, even if thin.

迁移后 `ProviderProfile` 中不再出现 `defp resolved_provider(:openai_codex)` 这类 provider-specific clause。

### 实施注意事项

- 不要为了减少文件数把多个 provider 写进同一个模块。
- 不要引入 “provider group” 共享 mutable state。
- 可抽取纯 helper，例如 `Nex.Agent.Turn.LLM.Providers.Helpers`, 但 helper 不能成为新的 policy dumping ground。

### 本 stage 验收

- 每个已知 provider 有独立 adapter module。
- `ProviderProfile` 只保留 struct/facade/common validation。
- `rg "openai_codex|openrouter|ollama" lib/nex/agent/llm/provider_profile.ex` 不应出现 provider-specific function clauses。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/llm/provider_profile_test.exs test/nex/agent/llm/req_llm_test.exs
```

## Stage 4

### 前置检查

- Stage 3 tests 通过。
- `OpenAICodex` adapter 已经 owns stream_text_fun。

### 这一步改哪里

- `lib/nex/agent/llm/providers/openai_codex/stream.ex`
- `lib/nex/agent/llm/providers/openai_codex/responses_policy.ex`
- `lib/nex/agent/llm/openai_codex_stream.ex`
- `lib/nex/agent/llm/openai_codex_responses_policy.ex`
- `test/nex/agent/llm/providers/openai_codex_test.exs`
- `test/nex/agent/llm/req_llm_test.exs`

### 这一步要做

把当前 root-level Codex stream/policy 模块迁入 provider namespace：

```elixir
Nex.Agent.LLM.Providers.OpenAICodex.Stream
Nex.Agent.LLM.Providers.OpenAICodex.ResponsesPolicy
```

删除旧 root-level 模块，更新 alias 和 tests。

补 OpenAI Codex adapter tests：

- adapter 选择 stream module。
- OAuth request body 包含 `instructions`。
- OAuth request body `store == false`。
- OAuth request body 不包含 `previous_response_id`。
- OAuth request body 不包含 `max_output_tokens`。
- reasoning replay item 不包含 `id`。
- API key mode 不走 Codex stream/policy。

### 实施注意事项

- 不要保留旧 root-level module 兼容别名；这是仓库内部 API，直接迁移调用点。
- 不要改 ReqLLM dependency。
- 不要让 custom/proxy Codex URL 走 OAuth policy。

### 本 stage 验收

- Codex provider 的特殊 contract 完全集中在 `providers/openai_codex/`。
- Root `llm/` 目录不再有 `openai_codex_stream.ex` / `openai_codex_responses_policy.ex`。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/llm/providers/openai_codex_test.exs test/nex/agent/llm/req_llm_test.exs
```

## Stage 5

### 前置检查

- Stage 4 tests 通过。
- Provider-specific files 已经迁移完成。

### 这一步改哪里

- `lib/nex/agent/llm/req_llm.ex`
- `lib/nex/agent/llm/provider_profile.ex`
- `lib/nex/agent/llm/provider_registry.ex`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/task-plan/index.md`

### 这一步要做

做最终收口：

- 确认 `ReqLLM` 只依赖 `ProviderProfile` facade。
- 确认 `ProviderProfile` 只依赖 registry/adapter，不再拥有 provider-specific policy。
- 确认 provider 默认模型归 adapter 所有，`ReqLLM` 不保留 provider-specific default model 分支。
- 确认 registry 列出所有 known providers。
- 更新 `CURRENT.md`，说明 Phase 12 是 LLM provider 接入真相源。
- 更新 task-plan index。

### 实施注意事项

- 不要同时重构 Runner/memory/channel 调用链。
- 不要引入热重载或配置 schema 变更；provider adapter phase 只整理 LLM 接入层。
- 不要改用户配置格式。

### 本 stage 验收

- 新 provider 接入路径在代码结构上清晰：
  1. 新建 `lib/nex/agent/llm/providers/<provider>.ex`
  2. 在 `ProviderRegistry` 注册
  3. 添加 focused provider tests
- 主链无 provider-specific module coupling。
- 默认模型选择不需要修改 `ReqLLM`。

### 本 stage 验证

```bash
/Users/krisxin/.local/bin/mise exec -- mix compile
/Users/krisxin/.local/bin/mise exec -- mix test test/nex/agent/llm/provider_registry_test.exs test/nex/agent/llm/provider_profile_test.exs test/nex/agent/llm/req_llm_test.exs test/nex/agent/memory_consolidation_test.exs
```

## Review Fail 条件

- `ReqLLM` 中出现具体 provider adapter module alias 或 provider-specific stream/payload branch。
- `ProviderProfile` 继续承载 `openai_codex` / `openrouter` / `ollama` 等 provider-specific policy function clauses。
- 任一 known provider 没有独立 adapter module。
- `openai-codex` OAuth 重新发送 `previous_response_id`、`max_output_tokens` 或 `store: true`。
- `openai-codex` API key/custom/proxy URL 错误套用 OAuth Codex policy。
- Provider adapter 读取配置文件、runtime 文件或 workspace 文件，而不是使用统一入口传入的数据。
- 新增 registry mutable state 或长期进程缓存 provider world view。
- Tests 只覆盖 happy path，没有覆盖 `openai-codex` OAuth/API-key 分叉。
