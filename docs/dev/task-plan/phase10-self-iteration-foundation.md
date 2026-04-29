# Phase 10: Self-Iteration Foundation

## 背景

Agent 的终极目标是自我迭代：能理解自己的代码、修改自己的实现、最小范围重启生效。

Phase 0 已验证（2026-04-23）：
- `HotReload` 编译加载新模块 ✓
- `Registry.hot_swap` 热替换已注册 tool ✓
- `CodeUpgrade` 升级 + 版本管理 + 回滚 ✓
- 语法错误自动回滚 ✓
- `UpgradeCode` tool 端到端自修改 ✓
- Gateway E2E：agent 通过 Discord 对话修改 Reflect 模块并即时生效 ✓

现有管线覆盖了 **read → modify → hot-reload → rollback**。缺的是 **observe → decide → verify** 这半圈。

## 目标

让 agent 从"能改自己"变成"能安全地、有意识地改自己并确认改对了"。

## 三个阶段

### Phase 10a — 结构化自我认知

**问题**：agent 现在改代码是盲改。它不知道模块间依赖、不知道改 X 会影响 Y、不知道自己的架构分层。E2E 测试中 agent 甚至猜错了自己的源码路径。

**做什么**：
- 一个 `introspect` tool（或扩展现有 `reflect`），输出：
  - 模块列表 + 每个模块的职责（`@moduledoc`）
  - 模块的 public API（`__info__(:functions)`）
  - 模块间依赖关系（谁 alias/import/use 了谁）
  - 模块的源码路径（消除路径猜测）
- 数据来源：BEAM runtime（`module_info`）+ 源码静态分析（grep alias/import）
- 不需要维护额外文档，每次调用实时计算

**验收**：agent 能通过 tool call 回答"Nex.Agent.Turn.Runner 依赖哪些模块？改它会影响什么？"

### Phase 10b — 变更验证闭环

**问题**：`CodeUpgrade` 的 health check 只验证模块能加载（`__info__(:functions)`），不验证行为正确。agent 改完代码不知道有没有改坏。

**做什么**：
- `upgrade_code` 流程增加 post-upgrade 验证步骤：
  - 根据被修改模块，定位对应的测试文件（约定：`lib/nex/agent/foo.ex` → `test/nex/agent/foo_test.exs`）
  - 热加载后自动跑相关测试
  - 测试失败 → 自动 rollback + 返回失败原因
  - 测试通过 → 保留变更
- 对于没有测试文件的模块，保持现有行为（只做 health check），但在返回结果中标注 `test_coverage: :none`

**验收**：agent 用 `upgrade_code` 改一个有测试的模块，故意引入 bug，系统自动回滚并告诉 agent 哪个测试失败了。

### Phase 10c — 自主触发

**问题**：现在只有用户主动要求 agent 才会改自己。要自我迭代，需要自主触发点。

**做什么**：
- Runner 的 error path 加一个钩子：当 tool 执行连续失败（同一 tool 在同一 session 内失败 N 次），agent 收到一个额外的 system hint："这个 tool 反复失败，你可以用 reflect 查看它的实现，判断是否需要用 upgrade_code 修复"
- 利用现有 `Cron` 机制，支持定期 self-review：agent 审视最近的错误日志和 audit trail，决定是否需要自我修复
- 不做复杂的 autonomous loop，只提供触发信号，决策权留给 LLM

**验收**：一个 tool 被故意写坏后，agent 在下次使用该 tool 失败时，能自主决定查看源码并尝试修复。

## 优先级

10a 和 10b 可以并行做，10c 依赖前两者。

10a 是认知基础，没有它 agent 改代码就是瞎改。
10b 是安全网，没有它 agent 改完不知道对不对。
10c 是从被动到主动的跨越，但前两者不到位就不应该让 agent 自主改代码。

## 风险

- **递归自毁**：agent 改坏了自己的 upgrade 管线。现有 `@protected_modules` 已经禁止修改 CodeUpgrade/UpgradeManager/Registry/Security，这个约束必须保留。
- **测试环境污染**：post-upgrade 跑测试时，测试可能依赖外部状态。需要确保只跑单元测试，不跑需要网络的集成测试。
- **认知时序错位**：agent 改了 Runner 或 ContextBuilder 后，当前对话仍然用旧逻辑。agent 需要理解"改动在下一轮对话生效"。这个通过 introspect tool 的返回信息说明。
