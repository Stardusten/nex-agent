# Phase 1 Runtime Reload Foundation

## 当前状态

- `Nex.Agent.Runtime.Config.load/0` 被多个调用点直接读取，配置真相源分散。
- `Nex.Agent.Turn.ContextBuilder.build_system_prompt/1` 每轮现读 `AGENTS.md`、`SOUL.md`、`USER.md`、`TOOLS.md`，但没有统一 runtime version。
- `Nex.Agent.Turn.Runner` 每轮现取 `Tool.Registry` definitions，但工具可见性和 prompt 层没有被同一份快照绑定。
- `Nex.Agent.Conversation.InboundWorker` 会缓存 session 对应的 agent struct，旧 agent 可能继续带旧 provider/model/tools/max_iterations。
- channel 进程在 `init/1` 读取配置后长期持有 state，配置变化不会自动传播。
- `Nex.Agent.Runtime.Prompt` 不是当前 runtime workspace 真相源，不能作为本 phase 的 resolver 基础。

## 完成后必须达到的结果

- 新增统一 runtime snapshot 真相源，后续主链不再各自直接读 `Config.load/0` 或零散拼接 runtime world view。
- config、prompt layers、tool definitions 至少能在下一轮用户 turn 以同一个 runtime version 生效。
- `Nex.Agent.Interface.Gateway` 不需要为了配置变更做全量 stop/start。
- session history 保留，但 stale agent 会在下一轮按当前 runtime snapshot 重建。
- 仓库中形成可继续推进的主链，后续 stage 可以在此基础上继续做 watcher 和 channel reconcile。

## 开工前必须先看的代码路径

- `lib/nex/agent/config.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/system_prompt.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/gateway.ex`
- `lib/nex/agent/channel/telegram.ex`
- `lib/nex/agent/channel/feishu.ex`
- `lib/nex/agent/channel/slack.ex`
- `lib/nex/agent/channel/discord.ex`
- `lib/nex/agent/channel/dingtalk.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/skills.ex`

## 固定边界 / 已冻结的数据结构与 contract

本 phase 固定以下边界：

1. 引入统一 runtime snapshot struct，最少包含：

```elixir
%Nex.Agent.Runtime.Snapshot{
  version: pos_integer(),
  config: Nex.Agent.Runtime.Config.t(),
  workspace: String.t(),
  prompt: %{
    system_prompt: String.t(),
    diagnostics: [map()],
    hash: String.t()
  },
  tools: %{
    definitions_all: [map()],
    definitions_subagent: [map()],
    definitions_cron: [map()],
    hash: String.t()
  },
  skills: %{
    always_instructions: String.t(),
    hash: String.t()
  },
  changed_paths: [String.t()]
}
```

2. runtime version 语义冻结：
   - 一个 version 表示一份完整、一致的 runtime world view
   - 不能混用 `prompt@N` 和 `tools@N-1`
3. workspace authoritative resolver 冻结为：
   - `Keyword.get(opts, :workspace) || Workspace.root(opts)`
   - 不使用 `SystemPrompt` 的硬编码 workspace 常量
4. `Runtime.reload/1` 顺序冻结为：
   - 解析 authoritative workspace
   - 读取 config
   - 构建 prompt
   - 从当前 `Tool.Registry` 读取 definitions
   - 从当前 `Nex.Agent.Capability.Skills` 读取 `always_instructions`
   - 组装 candidate snapshot
   - candidate 完整成功后才发布新 version
5. phase 1 的 runtime version contract 冻结为：
   - 包含 prompt layers
   - 包含 base tool definitions
   - 包含 `Skills.always_instructions/1`
   - 不包含 skill runtime per-turn selected packages
   - 不包含 skill runtime ephemeral tools
6. `%Nex.Agent{}` 上的字段冻结为 `runtime_version :: pos_integer() | nil`
   - 且必须在 `Nex.Agent.start/1`
   - `InboundWorker.ensure_agent/4`
   - `Nex.Agent.prompt/3` 返回后的 agent cache 回写
     这三个点被写入或刷新
7. 本 phase 不做“所有 channel 零抖动迁移”。
   - 连接类模块允许在后续 stage 做局部 reconnect
8. 本 phase 不改 session 持久化格式。
9. `TOOLS.md` 仍然是说明层，不作为真实 tool definitions 来源。

## 执行顺序 / stage 依赖

- Stage 1: 建立 runtime snapshot 真相源
- Stage 2: 让主调用链从 runtime 读
- Stage 3: 加入 stale agent 重建规则
- Stage 4: 接入 watcher 和最小 reconcile 主链

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 2。  
Stage 4 依赖 Stage 3。  
当前主线从 Stage 1 开始。

## Stage 1

### 前置检查

- 确认 `SystemPrompt` 当前不是实缓存，不要围绕它继续堆假 cache 接口。
- 确认 `ContextBuilder.build_system_prompt_with_diagnostics/1` 能给出 prompt 与 diagnostics。
- 确认 `Tool.Registry` 已有 `definitions/1`，避免重复造定义拼装逻辑。
- 确认 `Skills.always_instructions/1` 当前是缓存态入口，不要在 snapshot 外再做第二份长期缓存。

### 这一步改哪里

- 新增 `lib/nex/agent/runtime/snapshot.ex`
- 新增 `lib/nex/agent/runtime.ex`
- 更新 `lib/nex/agent/application.ex`
- 视需要新增 `test/nex/agent/runtime_test.exs`

### 这一步要做

- 定义 `Nex.Agent.Runtime.Snapshot` struct。
- 定义 `Nex.Agent.Runtime` GenServer，提供至少这些接口：
  - `current/0`
  - `current_version/0`
  - `reload/1`
  - `subscribe/0`
- `reload/1` 返回 contract 冻结为：

```elixir
{:ok, %Nex.Agent.Runtime.Snapshot{}} | {:error, reason}
```

- `current/0` 返回 contract 冻结为：

```elixir
{:ok, %Nex.Agent.Runtime.Snapshot{}} | {:error, :runtime_unavailable}
```

- `current_version/0` 返回 contract 冻结为：

```elixir
pos_integer() | nil
```

- `current_version/0` 的语义冻结为：
  - runtime 已完成初始 snapshot 启动后，返回当前 `snapshot.version`
  - 仅允许在 runtime 尚未可用时返回 `nil`
  - phase 1 主路径中的 stale 判定直接使用 `agent.runtime_version` 与当前整数 version 比较，不走 `{:ok, version}` tuple 分支

- `reload/1` 的执行顺序必须写死为：
  1. 解析 authoritative workspace
  2. 读取 config
  3. 构建 prompt 与 diagnostics
  4. 从当前 `Tool.Registry` 读取 `definitions(:all|:subagent|:cron)`
  5. 从当前 `Nex.Agent.Capability.Skills` 读取 `always_instructions`
  6. 计算 hash 并组装 candidate snapshot
  7. 成功后发布新 snapshot 与新 version
- 在 `reload/1` 中统一构建：
  - `config`
  - `prompt.system_prompt`
  - `prompt.diagnostics`
  - `tools.definitions_*`
  - `skills.always_instructions`
  - 对应 hash
- 初始启动时先构建 version 1 snapshot。
- `lib/nex/agent/application.ex` 中的启动顺序必须冻结为：
  - `Nex.Agent.Capability.Skills`
  - `Nex.Agent.Conversation.SessionManager`
  - `Nex.Agent.MessageBus`
  - `Nex.Agent.App.InfrastructureSupervisor`
  - `Nex.Agent.Runtime`
  - `Nex.Agent.App.WorkerSupervisor`
  - `Nex.Agent.ChannelSupervisor`
  - `Nex.Agent.Interface.Gateway`
- `Nex.Agent.Runtime` 必须位于 `Skills` 与 `InfrastructureSupervisor` 之后，且位于 `WorkerSupervisor` 与 `Gateway` 之前。
- phase 1 的初始启动失败语义冻结为：
  - 如果 version 1 snapshot 构建失败，则应用 fail-fast
  - 不引入长期 `runtime_unavailable` 降级启动模式
- 当 reload 成功时广播统一事件，事件 payload 至少包含：

```elixir
{:runtime_updated, %{old_version: old_v, new_version: new_v, changed_paths: paths}}
```

### 实施注意事项

- 不要在这个 stage 引入文件 watcher。
- `Runtime` 构建 snapshot 时可以继续复用现有模块，但外部主链先统一从 `Runtime` 拿结果。
- `Runtime.reload/1` 本身不得调用 `Tool.Registry.reload/0` 或 `Skills.reload/0`。
- snapshot 构建失败时不要覆盖上一个合法 snapshot。
- `workspace` 必须跟当前 `Workspace.root(opts)` 解析逻辑对齐，不要私自改 root 推断规则。
- 本 stage 的失败测试不要依赖“改坏 config 文件”。
- 失败源固定为可注入 builder failure：
  - 通过 `Runtime.reload/1` 的依赖注入参数，替换 prompt/tools/skills 某一段 builder 为返回 `{:error, reason}`
  - 用这个可控失败源验证“不污染最后一个合法 snapshot”

### 本 stage 验收

- 应用启动后存在一个可读取的 runtime snapshot。
- 手动调用 reload 时能生成新的 version。
- runtime snapshot 内同时包含 prompt、tools、skills 三部分，不是只有 config。
- version 1 snapshot 构建失败时，应用启动直接失败，不进入半可用状态。

### 本 stage 验证

- 新增单测覆盖：
  - 初始 snapshot 构建
  - reload 成功后 version 递增
  - reload 失败不污染最后一个合法 snapshot
  - authoritative workspace resolver 取值顺序
  - Runtime 启动顺序依赖：初始 snapshot 能读到已启动的 Skills 与 Tool.Registry
  - version 1 snapshot 构建失败时，应用启动 fail-fast，而不是进入半可用状态
- 运行：
  - `mix test test/nex/agent/runtime_test.exs`

## Stage 2

### 前置检查

- Stage 1 的 `Runtime.current/0` 已稳定返回 snapshot。
- 明确当前哪些主链还在直接 `Config.load/0`。
- 先冻结 `ContextBuilder.build_messages/6` 的新接口，再开始改调用点。

### 这一步改哪里

- `lib/nex/agent/runner.ex`
- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/gateway.ex`
- 对应测试：
  - `test/nex/agent/inbound_worker_test.exs`
  - `test/nex/agent/runner_evolution_test.exs`
  - 需要时新增 runtime 接入测试

### 这一步要做

- 让主链通过 runtime snapshot 取当前 config/prompt/tool definitions。
- `Runner` 不再在 LLM call 前直接向 `Tool.Registry` 现取主 definitions，而是优先使用 runtime snapshot 中同 version 的 definitions。
- `ContextBuilder.build_messages/6` 的新 contract 冻结为：

```elixir
build_messages(history, current_message, channel, chat_id, media, opts)
```

其中：

- `opts[:system_prompt]` 为必传主路径字段
- `build_messages/6` 不再在主路径内部调用 `build_system_prompt/1`
- `runtime_system_messages` 继续由 `build_messages/6` 追加到 `opts[:system_prompt]` 之后
- 拼接顺序冻结为：
  - `opts[:system_prompt]`
  - `runtime_system_messages`
  - history
  - current user message
- 仅允许 fallback 路径在 `opts[:system_prompt]` 缺失时临时调用 `build_system_prompt/1`，并且必须带日志，便于后续删掉
- `Gateway.do_send_message/1` 和 `InboundWorker.agent_start_opts/2` 改为从 runtime snapshot 取 provider/model/api_key/base_url/max_iterations/tools。
- 保留必要的 fallback，但 fallback 只允许在 `Runtime` 不可用时兜底，不允许主链继续双轨常驻。

### 实施注意事项

- 这一 stage 的目标是“主链换真相源”，不是顺手重写所有辅助路径。
- phase 1 不把 skill runtime ephemeral tools 放进 snapshot。
- `Runner` 当前 turn 仍然允许在 base definitions 之外追加 ephemeral tools。
- 这不违反 phase 1 contract，因为该类工具属于 per-turn prepared data，不属于 persisted runtime snapshot。
- 不要在这一步把 channel init 重构掉，先保住主请求路径。

### 本 stage 验收

- 一次 turn 内看到的 system prompt 与 tool definitions 来自同一 runtime version。
- 修改 runtime snapshot 后，新启动的 agent 与新一轮 `Runner` 调用使用更新后的 provider/model/tools。
- 主路径不再依赖零散 `Config.load/0` 拼 world view。

### 本 stage 验证

- 新增或更新测试覆盖：
  - runtime snapshot 驱动 `Runner` 取 prompt/tools
  - runtime snapshot 驱动 `InboundWorker` 创建 agent opts
- 运行：
  - `mix test test/nex/agent/runtime_test.exs`
  - `mix test test/nex/agent/inbound_worker_test.exs`
  - `mix test test/nex/agent/runner_evolution_test.exs`

## Stage 3

### 前置检查

- Stage 2 已让新建 agent 主链从 runtime snapshot 读。
- 确认 `InboundWorker` 当前缓存 agent 的位置与生命周期。

### 这一步改哪里

- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent.ex`
- 需要时新增 `lib/nex/agent/runtime/staleness.ex`
- 测试：
  - `test/nex/agent/inbound_worker_test.exs`

### 这一步要做

- 给 in-memory agent 标记 `runtime_version`。
- `%Nex.Agent{}` struct 新字段固定为 `runtime_version`，不要使用 `version` 这种泛化名字。
- 写入点固定为：
  - `Nex.Agent.start/1` 初始化 agent 时
  - `InboundWorker.ensure_agent/4` 新建 agent 时
  - `Nex.Agent.prompt/3` 返回新 agent 时
- stale 判定固定为：
  - 当 `Runtime.current_version/0` 大于 `agent.runtime_version` 时，该 agent stale
- stale agent 的处理规则固定为：
  - 保留 `SessionManager` 中的 session history
  - 丢弃旧 agent struct
  - 在下一轮用户消息到来时按当前 runtime snapshot 重建 agent
- 触发 stale 的变更至少包括：
  - config 变化
  - prompt layer 变化
  - tool definitions 变化

### 实施注意事项

- 不要清 session history。
- 不要为了这一步去改 session 文件结构。
- stale 检查应发生在 session agent 复用之前，而不是 run 完之后。
- agent 重建时必须重新取 runtime snapshot，而不是只覆盖 session 字段。

### 本 stage 验收

- 修改 `SOUL.md`、`TOOLS.md`、或 runtime config 后，已有 session 的下一轮消息会使用新 runtime version。
- 不需要执行 `/new` 才能看到新的 prompt/tool world view。

### 本 stage 验证

- 新增测试覆盖：
  - 旧 agent 在 runtime version 变化后被重建
  - session messages 仍然保留
- 运行：
  - `mix test test/nex/agent/inbound_worker_test.exs`
  - `mix test test/nex/agent/runtime_test.exs`

## Stage 4

### 前置检查

- Stage 3 已完成 runtime version 驱动的 stale agent 重建。
- 明确本 stage 只做“最小 watcher + 局部 reconcile 主链”，不做所有 channel 的高级状态迁移。
- 先确认 watcher 触发点里哪些变化需要先刷新 registry/skills，再触发 `Runtime.reload/1`。

### 这一步改哪里

- 新增 `lib/nex/agent/runtime/watcher.ex`
- 新增 `lib/nex/agent/runtime/reconciler.ex`
- 更新 `lib/nex/agent/application.ex`
- 更新 `lib/nex/agent/gateway.ex`
- 更新：
  - `lib/nex/agent/channel/telegram.ex`
  - `lib/nex/agent/channel/feishu.ex`
  - `lib/nex/agent/channel/slack.ex`
  - `lib/nex/agent/channel/discord.ex`
  - `lib/nex/agent/channel/dingtalk.ex`
- 新增或更新相关测试

### 这一步要做

- watcher 监听：
  - config path
  - workspace 下 `AGENTS.md`、`SOUL.md`、`USER.md`、`TOOLS.md`
  - `memory/MEMORY.md`
  - `skills/`
  - `tools/`
- 变更后 debounce，再调用 `Runtime.reload/1`。
- watcher / reconcile 的顺序冻结为：
  - 如果变化命中 `skills/`，先 `Skills.reload/0`
  - 如果变化命中 `tools/` 或 tool registration 相关路径，先 `Tool.Registry.reload/0`
  - 然后调用 `Runtime.reload/1`
  - 最后再处理 channel 局部 reconcile 与 stale agent 后续生效
- `Runtime.Reconciler` 订阅 runtime 事件并按模块处理：
  - 对 channel 进行按 child 的局部 restart/reconnect
- `Gateway` 不做全量 stop/start。
- 第一版 channel reconcile 规则：
  - enable/disable 变化：启动或终止对应 child
  - 连接参数变化：仅重启对应 child
  - 非连接态轻量配置变化可先用 restart 统一处理，不强求 in-place mutate

### 实施注意事项

- watcher 优先保证稳定，不要求引入复杂跨平台文件监听；必要时可以先采用可测试、可控的轮询实现。
- 这一 stage 的主 gate 是“无需重启 Gateway 即可生效”，不是“每个 channel 零重连”。
- 重启 child 前后必须保证 Bus 订阅链恢复正常。

### 本 stage 验收

- 修改 `config.json` 中 channel 开关或关键连接配置后，不重启 Gateway，相关 channel 能按预期局部刷新。
- 修改 `SOUL.md` / `TOOLS.md` / `skills/` / `tools/` 后，下一轮 turn 看到新 prompt 与新工具集。
- 新增 tool 不再出现“文档变了但模型看不到”的主链问题。

### 本 stage 验证

- 新增测试覆盖：
  - watcher 触发 reload
  - watcher 命中 `skills/` 后先 `Skills.reload/0`，再 `Runtime.reload/1`
  - watcher 命中 `tools/` 后先 `Tool.Registry.reload/0`，再 `Runtime.reload/1`
  - channel enable/disable 局部 reconcile
- 运行：
  - `mix test test/nex/agent/runtime_test.exs`
  - `mix test test/nex/agent/inbound_worker_test.exs`
  - `mix test test/nex/agent/tool_alignment_test.exs`
  - 针对新增 reconcile 测试文件的最小子集

## Review Fail 条件

- 继续让多个主链模块各自直接 `Config.load/0` 读取并长期保留自己的 world view。
- prompt、tool definitions、skills 仍然没有 runtime version 绑定。
- 通过“重启 Gateway”来掩盖 runtime reload 缺失。
- 让阶段结束时测试处于已知红状态，依赖后续阶段统一修复。
- 在 task plan 里留下未冻结的关键 contract，让执行者现场拍脑袋决定。
