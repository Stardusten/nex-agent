# Phase 15 Provider-Native Tool Capability Resolution

## 当前状态

当前仓库的 tool 主链仍然是“静态 registry + 单一实现”模型：

- `Nex.Agent.Tool.Registry` 直接注册具体 tool module，并把 `definition/0` 暴露给 LLM。
- `ReqLLM` 把这些 definitions 统一转成 function tools 发送给 provider。
- `openai-codex` 现在只是临时在 `ResponsesPolicy` 里把名为 `web_search` 的 function tool 改写成 built-in `{"type":"web_search"}`。
- 本地 `web_search` / `web_fetch` 仍然是固定的 DuckDuckGo / HTTP 抓取实现。

这会带来三类问题：

- 同一能力（例如 `web_search`）在“定义侧”和“执行侧”不是同一条控制链：定义是普通 function tool，provider request 里再做特殊改写。
- 当前没有一个统一真相源来判断“某个能力在当前 provider / auth mode / base_url / surface 下该用哪种实现”。
- 后续如果把 Codex 其余 provider-native 能力（至少 `image_generation`）接进来，很容易继续在 Registry、ReqLLM、provider policy、tool 模块里各长一份分支。

Phase 15 的目标不是先铺很多 provider-native tool，而是先建立一个 capability-resolved 主链：

- 用户和模型看到的是稳定的能力名，例如 `web_search`
- 系统内部再根据 provider/runtime 选择 native 或 local implementation
- 定义、执行、provider request rewrite、surface 过滤都走同一条 resolver

## 完成后必须达到的结果

1. repo 内新增统一的 tool capability resolution 边界，定义侧、执行侧、provider-native request policy 共用这一条真相源；不得继续在 `ResponsesPolicy`、`Tool.Registry`、`ReqLLM` 各自新增平行判断。
2. `web_search` 成为第一个 capability-resolved tool：
   - `openai-codex` + 官方 OAuth backend：走 provider-native built-in `web_search`
   - 其他 provider / custom codex backend：走现有本地 `web_search` 实现
3. `web_search` 对模型暴露的公共能力名保持不变：

```text
web_search
```

不得新增 `web_search_native`、`codex_web_search`、`openai_web_search` 之类平行 tool 名。

4. capability resolution 至少同时覆盖三件事：
   - definition shape
   - execution strategy
   - provider request rewrite / provider-native emission
5. `openai_codex_custom` 或任何第三方 codex-compatible base URL 默认不得启用 provider-native `web_search`；只有官方 Codex OAuth backend 可启用。
6. `web_search` capability strategy 至少支持：
   - `auto`
   - `provider_native`
   - `local`
7. runtime / config 对 `web_search` 的选择必须接到统一入口；业务模块不得自己读取散落配置文件做 provider-native 判定。
8. follow-up / subagent / cron / all surface 看到的 `web_search` 必须仍然是同一个能力名，但 resolution 可以按 surface 做受控差异；不得让某些 surface 同时泄漏 native 和 local 两个同名平行定义。
9. Phase 15 至少补齐 `web_search` 的以下 provider-native options contract：
   - `mode`: `live | cached | disabled`
   - `allowed_domains`
   - `user_location`
10. Phase 15 结束时，后续接 `image_generation` 之类 provider-native tool 时，不需要再改 `Tool.Registry` / `ReqLLM` 主链结构，只需新增 capability resolver 分支和 focused tests。

## 开工前必须先看的代码路径

- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/tool/behaviour.ex`
- `lib/nex/agent/tool/web_search.ex`
- `lib/nex/agent/tool/web_fetch.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/llm/req_llm.ex`
- `lib/nex/agent/llm/provider_profile.ex`
- `lib/nex/agent/llm/provider_adapter.ex`
- `lib/nex/agent/llm/providers/openai_codex.ex`
- `lib/nex/agent/llm/providers/openai_codex/responses_policy.ex`
- `lib/nex/agent/auth/codex.ex`
- `test/nex/agent/llm/providers/openai_codex_test.exs`
- `test/nex/agent/tool_alignment_test.exs`
- `docs/dev/findings/2026-04-16-openai-native-computer-use-architecture.md`

## 固定边界 / 已冻结的数据结构与 contract

1. 用户/模型可见的能力名冻结为：

```text
web_search
web_fetch
```

本 phase 不改名，不新增 provider-specific alias。

2. provider-native capability resolution 最小结果 shape 冻结为：

```elixir
%{
  "tool_name" => String.t(),
  "strategy" => "local" | "provider_native" | "disabled",
  "definition" => map() | nil,
  "provider_native" => %{
    "type" => String.t(),
    optional("options") => map()
  } | nil
}
```

允许内部实现用 struct，但对外 reducer / trace / tests 必须能映射到这个最小 shape。

3. `web_search` capability config 最小 contract 冻结为：

```elixir
%{
  optional("strategy") => "auto" | "provider_native" | "local",
  optional("mode") => "live" | "cached" | "disabled",
  optional("allowed_domains") => [String.t()],
  optional("user_location") => %{
    optional("country") => String.t(),
    optional("region") => String.t(),
    optional("city") => String.t(),
    optional("timezone") => String.t()
  }
}
```

4. Phase 15 不改变 `Nex.Agent.Tool.Behaviour` 现有 execute contract：

```elixir
@callback execute(map(), map()) :: {:ok, any()} | {:error, String.t()}
```

provider-native tool 不通过 tool module 本地执行时，可以跳过 `execute/2`，但不得把 provider-native 调度伪装成另一个本地 tool 名。

5. `openai-codex` provider-native `web_search` 启用条件冻结为：

```text
provider == :openai_codex
and auth_mode == :oauth
and base_url == Codex.default_base_url()
```

只要任一条件不满足，就必须回退到 local 或 disabled，不允许冒进启用 native search。

6. `openai_codex_custom` 与第三方 codex-compatible backend 冻结为：

```text
never auto-enable provider-native web_search in Phase 15
```

7. `web_search` provider-native built-in tool shape 冻结为：

```json
{
  "type": "web_search",
  "external_web_access": true | false,
  "filters": {
    "allowed_domains": ["example.com"]
  },
  "user_location": {
    "type": "approximate",
    "country": "US",
    "region": "California",
    "city": "San Francisco",
    "timezone": "America/Los_Angeles"
  }
}
```

`external_web_access` 与 `mode` 的映射冻结为：

- `live` -> `true`
- `cached` -> `false`
- `disabled` -> tool 不注入 request

8. 本 phase 不改以下边界：

- 不改 `web_fetch` 的本地 fetch/parse 主链
- 不接 `image_generation`
- 不接 `computer_use` / `browser_use`
- 不改 tool surface 过滤模型（`:all` / `:follow_up` / `:subagent` / `:cron`）的基本语义
- 不改 `ReqLLM` 的通用 function-tool 转换主链，除非 capability resolver 需要最小接口扩展

9. 真相源冻结：

provider-native capability 判定只能依赖：

- `ProviderProfile`
- 统一 capability resolver
- runtime/config accessor

不得在 tool 模块、channel、worker、prompt builder 中各自复制一份 `provider == :openai_codex and oauth` 判断。

10. 验收前必须修复当前已知偏差：

`ProviderProfile.default_api_key(:openai_codex)` 现在没有正确反映 `Auth.Codex.resolve_access_token/0` 的可用状态；若继续沿 capability mainline 使用 provider profile 作为真相源，这个 facade 偏差必须一并收口。

## 执行顺序 / stage 依赖

- Stage 0：preflight，冻结现状与 contract tests
- Stage 1：引入 capability resolver 主链
- Stage 2：把 `web_search` 迁移到 capability-resolved definition/execution
- Stage 3：接入 `openai-codex` provider-native `web_search` options
- Stage 4：去掉临时 ad-hoc rewrite，收口到统一 resolver
- Stage 5：文档、progress、后续 provider-native expansion notes

Stage 1 依赖 Stage 0。  
Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 2。  
Stage 4 依赖 Stage 3。  
Stage 5 依赖 Stage 4。  

## Stage 0

### 前置检查

- 当前 `openai_codex` OAuth backend 已经能通过真实请求触发 built-in `web_search`。
- focused test 已覆盖当前 `ResponsesPolicy` 临时 rewrite 行为。
- 不读取 `~/.nex`。

### 这一步改哪里

- `test/nex/agent/llm/providers/openai_codex_test.exs`
- `test/nex/agent/tool_alignment_test.exs`
- `test/nex/agent/runner_*`

### 这一步要做

- 先补 guard tests，冻结当前能力 contract：
  - `web_search` 对模型仍然只暴露一个能力名
  - `openai_codex` OAuth backend 走 built-in `web_search`
  - 非官方 backend 不走 native
  - `follow_up` surface 仍可看到 `web_search`
- 补一个 focused test 暴露 `ProviderProfile.default_api_key(:openai_codex)` 当前 facade 偏差。

### 实施注意事项

- 这一 stage 不重构主链，只补测试。
- 不新增临时 compatibility layer。

### 本 stage 验收

- 后续 capability resolver 重构如果破坏 `web_search` 现有 contract，会先在 focused tests 失败。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/llm/providers/openai_codex_test.exs test/nex/agent/tool_alignment_test.exs
```

## Stage 1

### 前置检查

- Stage 0 tests 通过。
- 明确 capability resolver 是唯一真相源，而不是给每个 tool 各写一个 `enabled?`。

### 这一步改哪里

- `lib/nex/agent/tool/capability_resolver.ex`
- `lib/nex/agent/tool/capability.ex`
- `lib/nex/agent/llm/provider_profile.ex`
- `lib/nex/agent/tool/registry.ex`
- `test/nex/agent/tool/capability_resolver_test.exs`

### 这一步要做

- 新增 capability resolver 边界，输入至少包含：
  - tool name
  - provider profile
  - runtime/config
  - surface
- 输出至少包含：
  - definition strategy
  - execution strategy
  - provider-native strategy
- `Tool.Registry.definitions/1` 改为通过 resolver 生成最终 definitions，而不是直接盲发 module.definition/0。

### 实施注意事项

- 不要让 `Tool.Registry` 自己理解 provider-native 细节。
- 不要在 `ReqLLM` 主链增加新的 provider-specific if-else。

### 本 stage 验收

- capability resolver 成为统一入口。
- tool definition 侧不再需要临时 provider-specific ad-hoc 判断。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/tool/capability_resolver_test.exs test/nex/agent/tool_alignment_test.exs
```

## Stage 2

### 前置检查

- Stage 1 resolver 已经稳定输出 `web_search` resolution。

### 这一步改哪里

- `lib/nex/agent/tool/web_search.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/runner.ex`
- `test/nex/agent/tool_alignment_test.exs`
- `test/nex/agent/follow_up_test.exs`

### 这一步要做

- 把 `web_search` 从“固定本地实现”迁移为 capability-resolved tool：
  - local strategy：仍走现有 `WebSearch.execute/2`
  - provider-native strategy：definition 不再伪装成普通 function tool
- 保持 `follow_up` / `cron` / `all` surface 对 `web_search` 的同名可见性。

### 实施注意事项

- 不要引入第二个 registry name。
- 不要在 follow-up surface 泄漏两个并存的 `web_search` definition。

### 本 stage 验收

- `web_search` capability 在 definition/execution 两侧都走 resolver。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/tool_alignment_test.exs test/nex/agent/follow_up_test.exs
```

## Stage 3

### 前置检查

- `web_search` capability-resolved 主链已经稳定。

### 这一步改哪里

- `lib/nex/agent/llm/providers/openai_codex.ex`
- `lib/nex/agent/llm/providers/openai_codex/responses_policy.ex`
- `lib/nex/agent/tool/capability_resolver.ex`
- `lib/nex/agent/config.ex`
- `test/nex/agent/llm/providers/openai_codex_test.exs`
- `test/nex/agent/config_test.exs`

### 这一步要做

- 为 `web_search` 接 provider-native options：
  - `mode`
  - `allowed_domains`
  - `user_location`
- 把这些 options 接到统一 config/runtime accessor，而不是让 provider 或 tool 自己裸读配置。
- 修复 `ProviderProfile.default_api_key(:openai_codex)` facade，使 provider profile 真相源与 `Auth.Codex.resolve_access_token/0` 对齐。

### 实施注意事项

- 配置规范化放在真相源附近，不要散落在 channel / worker / provider policy。
- 不要为了省事在 `ResponsesPolicy` 里直接拼一整套 config parsing。

### 本 stage 验收

- `web_search` native request shape可由 resolver + config 统一决定。
- `default_api_key` facade 偏差被收口。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/llm/providers/openai_codex_test.exs test/nex/agent/config_test.exs
```

## Stage 4

### 前置检查

- Stage 3 的 native `web_search` 已能通过真实 OAuth backend 验证。

### 这一步改哪里

- `lib/nex/agent/llm/providers/openai_codex/responses_policy.ex`
- `lib/nex/agent/tool/capability_resolver.ex`
- `test/nex/agent/llm/providers/openai_codex_test.exs`

### 这一步要做

- 删除当前 ad-hoc rewrite 形态，把 native `web_search` emission 完全交给 resolver 输出。
- 让 `ResponsesPolicy` 只处理 Codex backend 的 payload policy，不再承担 capability 选择职责。

### 实施注意事项

- 不要把 resolver 结果再翻译回 function tool 再重写一次。
- review 时重点检查有没有残留平行分支。

### 本 stage 验收

- provider-native `web_search` 不再依赖 ad-hoc special-case。

### 本 stage 验证

```bash
/opt/homebrew/bin/mix test test/nex/agent/llm/providers/openai_codex_test.exs test/nex/agent/tool/capability_resolver_test.exs
```

## Stage 5

### 前置检查

- 前四个 stage 已全部验收。

### 这一步改哪里

- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/2026-04-24.md`
- `docs/dev/findings/*`（仅在出现新的架构结论时）

### 这一步要做

- 记录 capability-resolved tool 主线已建立。
- 明确后续 Phase 15 follow-up 候选：
  - `image_generation` provider-native 化
  - 其他 provider-native capability inventory

### 实施注意事项

- 不要在 Phase 15 内顺手接 `image_generation`。
- findings 只写架构结论，不写流水账。

### 本 stage 验收

- `CURRENT.md` 已把主线切到 capability resolution。
- 后续执行者可以直接按该 phase 开工。

### 本 stage 验证

- 人工检查：
  - `CURRENT.md` 已引用 Phase 15
  - progress 记录与阶段边界一致

## Review Fail 条件

- 仍然在 `ResponsesPolicy`、`Tool.Registry`、`ReqLLM`、tool module 中各自维护一份 provider-native 判定
- 为 native/local 两种实现暴露两个不同的 `web_search` tool 名
- `openai_codex_custom` 或第三方 backend 被错误自动启用 provider-native `web_search`
- `web_search` 配置没有接到统一 runtime/config 入口，而是在业务模块里自己裸读配置
- 只改 definition 不改 execution，或只改 request rewrite 不改 definition，继续保持双轨不一致
- 为了兼容中间状态引入长期保留的 shim / hidden fallback contract
