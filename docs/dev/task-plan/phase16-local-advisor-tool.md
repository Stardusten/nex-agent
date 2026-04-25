# Phase 16 Local Advisor Tool (Subagent-Backed Consultation)

## 当前状态

我们已经有三块可复用底盘：

- 子代理 profile（含 `model_role`、`tools_filter`、`context_window`、`return_mode`）。
- `subagent` profile 可以通过运行时配置加载，`runner` 和工具链都支持 profile-aware 调度。
- `ReqLLM` 与 `Runner` 已经统一收口到 model role。

本阶段目标不是重构 subagent，而是在 owner run 中新增“本地工具式 advisor 咨询能力”，并支持“完整上下文 / 最近上下文”自动注入。

## 完成后必须达到的结果

1. 新增一个名为 `ask_advisor` 的本地 function tool（`category` 为工具层面可见的默认层），用于 owner run 在执行中主动申请建议。
2. `ask_advisor` 工具支持自动上下文继承，不要求主模型显式传完整 parent 历史。
3. `ask_advisor` 增加可枚举的上下文选项：
   - `context_mode: "full"`：自动读取父会话完整消息历史（在单次调用内做长度裁剪）。
   - `context_mode: "recent"`：自动读取最近 N 条上下文（默认使用 profile 的 `context_window` 或配置默认值）。
   - `context_mode: "none"`：不注入父会话上下文。
   - `context`：可选，支持调用方手工传入一段额外上下文文本（与 `context_mode` 结果叠加）。
4. `ask_advisor` 仍采用本地 tool 的方式执行（本地 prompt + 本地 runner），不新增 provider-native 代码路径。
5. advisor 调用使用 `advisor` model role（通过已有 runtime config），并写入 ControlPlane 可观测事件（已开始/完成/失败）。
6. `spawn_task` 保持现状，不因 advisor 引入而扩大职责；advisor 与普通 background subagent 的投递语义（`inbound`/`silent`）不混用。
7. 工具列表与运行时可见面（`:all`、owner 场景）包含 `ask_advisor`，跟 `follow_up` / `subagent` 暴露面保持既有冻结边界。
8. 验收命令覆盖：
   - `tool_alignment` 中新增对 `ask_advisor` 参数与返回行为的检查。
   - 一条针对 `context_mode=full/recent/none` 的工具行为测试。
   - 一条针对 `advisor_model_runtime` 的调用路径测试（provider/model/options 与会话上下文注入一致）。

## 开工前必须先看的代码路径

- `docs/dev/designs/2026-04-25-advisor-mode-design-notes.md`
- `docs/dev/task-plan/2026-04-25-local-tool-backend-selection.md`
- `docs/dev/findings/2026-04-25-local-tool-backend-selection.md`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/tool/spawn_task.ex`
- `lib/nex/agent/subagent/profile.ex`
- `lib/nex/agent/subagent/profiles.ex`
- `lib/nex/agent/subagent.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/runner.ex`
- `test/nex/agent/tool_alignment_test.exs`
- `test/nex/agent/subagent_profile_test.exs`
- `test/nex/agent/runner_evolution_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

### 1) `ask_advisor` tool contract（冻结）

参数 shape：

```text
%{
  "question" => String.t(),
  optional("context_mode") => "full" | "recent" | "none",
  optional("context_window") => pos_integer(),
  optional("profile") => String.t(),
  optional("context") => String.t(),
  optional("model_key") => String.t()
}
```

规则：

- `question` 为必填。
- `context_mode` 默认 `recent`。
- `context_window` 仅在 `context_mode=recent` 有效。
- `context` 是调用方手工提供的上下文文本。若存在，会在 `question` 之后、自动继承上下文之后追加（若需要）。
- `profile` 默认选本地 `advisor` profile；若调用方显式传入未知 profile，返回稳定错误。
- 任何上下文注入都不能直接改变父会话消息。

### 2) Context 注入策略（冻结）

- `full`：读取父会话完整历史消息，按单次调用安全上限进行裁剪，不改变父会话本体。
- `recent`：读取父会话 `Session.get_history(profile.context_window || 12)`。
- `none`：不自动读取父会话消息，仅用调用方 `context`（若有）。
- 上下文合成顺序固定为：`question` -> 自动上下文（按 `context_mode`）-> `context`。
- 上下文注入块必须包含来源标记，便于定位（如“Advisor context from parent session ...”）。

### 3) advisor 运行 contract（冻结）

- profile 解析优先级：`profile` 参数 > 运行时 `subagents` 中定义的内置/自定义 profile。
- model 解析：遵循 `model_role` / `model_key`，优先走 `advisor` model role。
- provider options 使用 profile 配置；tool 层不得添加 provider 专有分支。
- 运行 `Runner.run/3` 时设置 `skip_consolidation: true`，`tools_filter` 默认保守（最小安全）。

### 4) 结果返回与可见性（冻结）

- `ask_advisor` 是同步工具：返回一段建议文本给当前 owner run。
- advisor 的建议默认不自动变成可见用户消息；只作为模型内部 tool result 使用。
- 允许在 profile 配置中明确要求更强返回策略，但第一阶段不支持向用户单独发送。

### 5) 可观测性 contract（冻结）

新增观测 tag（与既有 tool observation 风格一致）：

- `advisor.call.started`
- `advisor.call.finished`
- `advisor.call.failed`

至少记录：`run_id`、`session_key`、`workspace`、`question_hash`、`question_preview`、`context_mode`、`context_window`、`profile`、`duration_ms`、`provider`、`model`。

## 执行顺序 / stage 依赖

- Stage 0：冻结边界确认与测试基线。
- Stage 1：新增 `ask_advisor` 工具与最小输入 contract。
- Stage 2：上下文继承实现（full/recent/none）。
- Stage 3：advisor 工具注入 runner，并接入 profile/model role。
- Stage 4：可观测性 + 工具表面收敛。
- Stage 5：提示词/文档提示与端到端验收。

Stage 1 依赖 Stage 0。
Stage 2 依赖 Stage 1。
Stage 3 依赖 Stage 2。
Stage 4 依赖 Stage 3。
Stage 5 依赖 Stage 4。

## Stage 0

### 前置检查

- `docs/dev` 的主流程文档已更新（`CURRENT.md` 和设计/发现链路）
- 当前测试基线可复现，`config/runtime/tool_alignment/subagent_profile` 的关键用例通过。

### 这一步改哪里

- `docs/dev/task-plan/phase16-local-advisor-tool.md`
- `docs/dev/task-plan/index.md`（新增索引条目）

### 这一步要做

- 锁定本阶段不需要的复杂度：
  - 不加新 provider-native executor
  - 不加新的 session fork 抽象
  - 不新增专属 controller/agent lane
- 确认 `ask_advisor` 只做同步咨询，不做 code/write/部署。

### 实施注意事项

- 不把 `ask_advisor` 做成 subagent 的副本；以本地 tool 执行为第一原则。
- 不引入新 `context_mode` 全局解析器；局部到该工具参数。

### 本 stage 验收

- 本阶段只形成执行文档，无代码逻辑变更。

### 本 stage 验证

- 人工复核：tool、subagent、control-plane 与 prompt 边界不冲突。

## Stage 1

### 前置检查

- Stage 0 完成。

### 这一步改哪里

- `lib/nex/agent/tool`
- `lib/nex/agent/tool/registry.ex`

### 这一步要做

- 新建 `lib/nex/agent/tool/ask_advisor.ex`
  - `name/0` => `ask_advisor`
  - `category/0` 设为 owner 可见默认分类（不放入 follow_up/subagent 黑名单外流）
  - `definition/1` 使用可选参数 `context_mode/context_window/context/profile/model_key`

- 更新 `@default_tools`：注册 `Nex.Agent.Tool.AskAdvisor`。

### 实施注意事项

- `context_mode` / `context_window` 只定义形状，不在此 stage 执行 context 读取。
- 禁止从这个 stage 开始直接改 `tools_filter` 与 subagent 流程。

### 本 stage 验收

- owner run 的 tool surface 中出现 `ask_advisor`。

### 本 stage 验收测试

- `Advisor tool definition exposes question/context_mode/context_window options`（新增到 `test/nex/agent/tool_alignment_test.exs`）。

### 本 stage 验证命令

- `mix test test/nex/agent/tool_alignment_test.exs`

## Stage 2

### 前置检查

- Stage 1 完成。

### 这一步改哪里

- `lib/nex/agent/tool/ask_advisor.ex`
- `lib/nex/agent/context_builder.ex`（若需要在系统提示里暴露使用时机）

### 这一步要做

- `ask_advisor` 内实现上下文注入分支：
  - `full`：读取 parent session 全历史。
  - `recent`：读取 recent window（默认 12 或 profile window）。
- `none`：不自动注入，只按 `context` 决定是否附加手工上下文。
- 加入 context 来源标记和长度上限截断，避免单次上下文注入过大导致请求失控。
- 增加从 ctx 自动取 `session_key / workspace` 的逻辑，保持 owner run 上下文依赖集中。

### 实施注意事项

- 不能使用 `SessionManager.get/2` 返回 `nil` 导致崩溃。
- 全量上下文只读，不改变/重写父会话。

### 本 stage 验收

- 同一条 parent 会话在不同 `context_mode` 下能被正确选取。
- 在 `context_mode=full/recent/none` 下返回不同 prompt 形状。

### 本 stage 验证测试

- 新增 `test/nex/agent/tool/ask_advisor_test.exs`：
  - recent 模式读到 parent window
  - full 模式读到完整父会话（可验证调用消息中包含早期 user/assistant role）
  - none 模式不含 parent_context
  - `context` 参数在不同 `context_mode` 下始终可见且按顺序追加

### 本 stage 验证命令

- `mix test test/nex/agent/tool/ask_advisor_test.exs`

## Stage 3

### 前置检查

- Stage 2 完成。
- `SubagentProfiles` 与 `Config` 的 model role/runtime 可读取。

### 这一步改哪里

- `lib/nex/agent/tool/ask_advisor.ex`
- `lib/nex/agent/subagent/profile.ex`
- `lib/nex/agent/subagent/profiles.ex`
- `lib/nex/agent/config.ex`（如需）

### 这一步要做

- 接上实际执行链路：`ask_advisor` 使用 `model_role: :advisor` 跑独立的 `Runner.run/3`，并把 `question + 自动上下文 + context` 构造成提示词。
- profile 选择与覆盖：
  - `profile` 参数 -> 尝试读取 runtime profile。
  - 未传则使用运行时 `advisor` profile，若没有则使用 tool 内置的本地 `advisor` profile。
- 可选 `model_key` 作为 profile 外的执行 override（仅当前阶段允许），保持参数边界极小。

### 实施注意事项

- 不让 advisor tool 触发 `Bus` 可见消息。
- 不在此阶段允许任何 `message` 或 `self_update` 侧作用。
- advisor 第一阶段固定无工具执行；profile 只影响 prompt/model/options，不扩大 advisor 的工具能力。

### 本 stage 验收

- 在测试中能验证：
  - `provider` 与 `model` 从 advisor profile/model role 出口正确。
  - tool 返回可供 owner run 继续使用的纯文本。

### 本 stage 验证测试

- `test/nex/agent/tool/ask_advisor_test.exs`（advisor 调用链路）
- `test/nex/agent/tool/ask_advisor_test.exs` 校验默认 advisor profile、显式 profile、未知 profile 错误。

### 本 stage 验证命令

- `mix test test/nex/agent/tool/ask_advisor_test.exs test/nex/agent/subagent_profile_test.exs`

## Stage 4

### 前置检查

- Stage 3 完成。

### 这一步改哪里

- `lib/nex/agent/control_plane/log.ex`
- `lib/nex/agent/tool/ask_advisor.ex`

### 这一步要做

- 记录 `advisor.call.started/finished/failed` 观测事件，包含 `question_hash`/`question_preview`/`profile`/`context_mode`。
- 工具层执行失败时返回稳定错误文案，避免直接抛异常。
- 更新 tool alignment test，确保运行时 surface 未把 advisor 暴露到不该有的面（至少 `follow_up`/`subagent` 保持默认不变）。

### 实施注意事项

- 切勿复用 subagent 的 bus 回传路径。
- event 里不要写完整用户问题明文，建议保留短 hash 或截断片段。

### 本 stage 验收

- `observe` 查询能看到 advisor 调用记录。
- 失败路径落地为可追踪、可读的 `reason`。

### 本 stage 验证测试

- `test/nex/agent/tool_alignment_test.exs`
- `test/nex/agent/tool/ask_advisor_test.exs` 查询 `advisor.call.*` 的最小断言。

### 本 stage 验证命令

- `mix test test/nex/agent/tool_alignment_test.exs test/nex/agent/tool/ask_advisor_test.exs`

## Stage 5

### 前置检查

- Stage 4 完成。
- 合并 `docs/dev/task-plan/index.md`。

### 这一步改哪里

- `docs/dev/task-plan/index.md`
- `lib/nex/agent/context_builder.ex`
- `docs/dev/progress/2026-04-25.md` 或新的同日 progress（可选）

### 这一步要做

- 给模型一个明确的建议约束：在判断“自己无法继续/需要复核/要评估方案风险”时可调用 `ask_advisor`。
- 形成本阶段执行总结（含新选项含义）。
- 更新执行计划入口，方便下个阶段接续。

### 实施注意事项

- prompt 提示要讲明 advisor 建议默认用于 owner 内部，不默认对用户可见。

### 本 stage 验收

- 运行时文档与实际可见工具名一致。

### 本 stage 验证测试

- `mix test test/nex/agent/context_builder_test.exs`

### 本 stage 验收命令

- `mix test test/nex/agent/context_builder_test.exs test/nex/agent/tool/ask_advisor_test.exs`

## Review Fail 条件

- 把 advisor 做成 provider-native lane（例如新 provider 策略开关）。
- 让 `ask_advisor` 通过 `spawn_task` 返回异步 task id，而不是同步建议。
- `ask_advisor` 将建议直接发回前端新消息。
- 忽略 `session_key`，要求模型每次手工传 parent 上下文。
- 全量上下文调用无裁剪直接拼入导致请求长度失控。
- 复用 `:subagent` 工具列表直接泄露本阶段不应有工具，或将 advisor 暴露到 follow-up 的只读面。
- 缺少 `advisor.call.*` 观测，无法回放咨询动作。
- 为了“方便”新增过多中间抽象（独立 profile-run 运行时子系统、专属 scheduler、provider-native adapter）。
