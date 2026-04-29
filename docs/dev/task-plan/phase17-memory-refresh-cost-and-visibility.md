# Phase 17 Memory Refresh Cost And Visibility

## 当前状态

当前记忆系统已经形成一条可用主链：

- `memory/MEMORY.md` 是 workspace 级长期事实真相源。
- `workspace/USER.md` 是用户画像真相源。
- session JSONL 保存原始对话历史，`last_consolidated` 标记已被记忆 refresh 处理到哪里。
- `Memory.refresh/4` 会读取未处理 session messages，让 LLM 调内部 `save_memory` tool，返回 `noop` 或整份更新后的 `MEMORY.md`。
- `MemoryUpdater` 串行化后台 refresh，避免并发写 `MEMORY.md`。

当前问题：

1. refresh 复用当前 owner run 的 provider/model，可能把普通后台整理跑在昂贵模型上。
2. refresh 是隐式后台动作，用户看不到什么时候学到了什么。
3. `Memory.refresh/4` 只返回 `:noop | :updated`，没有稳定 summary、hash、notice metadata。
4. `MemoryUpdater` job 只带 workspace/session/model 信息，不带当前 channel/chat_id，所以后台 refresh 不能可靠投递用户可见 notice。

本阶段不解决触发频率和 ops-based memory merge，只先做成本控制和可见性。

## 完成后必须达到的结果

1. 新增 `memory_model` model role，并提供统一 resolver：
   - 优先 `model.memory_model`
   - 其次 `model.cheap_model`
   - 最后 `model.default_model`
2. 所有记忆整理路径默认使用 memory refresh runtime，而不是 owner run 的模型：
   - owner run 后台 refresh
   - `memory_consolidate`
   - `memory_rebuild`
3. `save_memory` 内部 tool contract 支持一条短 summary，用于 notice 和观测。
4. 每次成功写入长期记忆时，当前用户会收到一条轻量 notice：
   - 格式固定为 `🧠 Memory - <summary>`
   - 只在真实更新时发送
   - `noop` 不发送
5. notice 只在用户可见 owner/chat 场景发送；cron、subagent、follow-up、silent/internal refresh 不发送。
6. ControlPlane 记录 memory update 的 summary、before/after hash、model role、provider/model、session_key。
7. 现有 `MEMORY.md` 读写主链保持不变：本阶段不引入向量库、不引入新 memory DB、不改成 ops merge。

## 开工前必须先看的代码路径

- `docs/dev/findings/2026-04-25-memory-system-cost-visibility-and-triggering.md`
- `lib/nex/agent/config.ex`
- `lib/nex/agent/runtime.ex`
- `lib/nex/agent/runtime/snapshot.ex`
- `lib/nex/agent.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/memory.ex`
- `lib/nex/agent/memory_updater.ex`
- `lib/nex/agent/outbound.ex`
- `lib/nex/agent/bus.ex`
- `lib/nex/agent/tool/memory_consolidate.ex`
- `lib/nex/agent/tool/memory_rebuild.ex`
- `lib/nex/agent/tool/memory_write.ex`
- `lib/nex/agent/tool/memory_status.ex`
- `test/nex/agent/config_test.exs`
- `test/nex/agent/memory_consolidation_test.exs`
- `test/nex/agent/memory_updater_test.exs`
- `test/nex/agent/memory_consolidate_test.exs`
- `test/nex/agent/memory_rebuild_test.exs`
- `test/nex/agent/memory_write_test.exs`
- `test/nex/agent/inbound_worker_memory_refresh_test.exs`
- `test/nex/agent/runner_evolution_test.exs`

## 固定边界 / 已冻结的数据结构与 contract

### 1) Config model role contract

新增外部 config key：

```elixir
%{
  "model" => %{
    "default_model" => String.t(),
    "cheap_model" => String.t() | nil,
    "advisor_model" => String.t() | nil,
    "memory_model" => String.t() | nil,
    "models" => %{optional(String.t()) => map()}
  }
}
```

新增 accessor：

```elixir
@spec memory_model_runtime(Nex.Agent.Runtime.Config.t()) :: Nex.Agent.Runtime.Config.model_runtime() | nil
def memory_model_runtime(config)
```

行为 contract：

```elixir
memory_model_runtime(config) ||
  cheap_model_runtime(config) ||
  default_model_runtime(config)
```

`memory_model` 未配置时不能让 memory refresh 失败；必须 fallback。

### 2) Memory refresh result contract

`Memory.refresh/4` 返回结构化结果，不只返回 atom：

```elixir
@type refresh_status :: :noop | :updated

@type refresh_result :: %{
  status: refresh_status(),
  summary: String.t() | nil,
  before_hash: String.t(),
  after_hash: String.t(),
  memory_bytes: non_neg_integer(),
  model_role: "memory",
  provider: String.t(),
  model: String.t()
}

@spec refresh(Session.t(), atom(), String.t(), keyword()) ::
  {:ok, Session.t(), refresh_result()} | {:error, term()}
```

所有调用点必须迁移到 `refresh_result.status`，不要保留旧 atom tuple 兼容分支。

### 3) Internal `save_memory` tool contract

内部 tool 参数 shape：

```elixir
%{
  "status" => "noop" | "update",
  optional("memory_update") => String.t(),
  optional("summary") => String.t()
}
```

规则：

- `status=noop` 时忽略 `summary`，不发送 notice。
- `status=update` 时必须提供非空 `memory_update`。
- `status=update` 时应提供短 `summary`，用于 notice。
- 若 `summary` 缺失但 `memory_update` 确实变化，运行时可用稳定兜底文案 `Memory updated.`，但测试应覆盖 summary 正常路径。
- `summary` 进入 notice 前必须 trim、单行化、截断到 140 字符以内。

### 4) Notice contract

用户可见 notice 固定 shape：

```text
🧠 Memory - <summary>
```

发送条件：

- refresh result `status == :updated`
- notice target 存在：`channel` 和 `chat_id`
- 当前上下文不是 cron、subagent、follow-up、silent/internal
- 同一个 refresh job 只发送一次 notice

禁止：

- `noop` 发送 notice
- 因 `memory_status` 发送 notice
- 在 follow-up turn 发送 notice
- 在 subagent child session 发送 notice
- 在 cron run 发送 notice

### 5) Memory write notice contract

`memory_write`、`memory_consolidate`、`memory_rebuild` 在当前 user-visible context 里真实改变 `MEMORY.md` 时也要走同一 notice renderer。

规则：

- `memory_write append/set` 成功写入后发送 notice。
- `memory_consolidate` 只有 refresh result `:updated` 时发送 notice。
- `memory_rebuild` 只有 promote 后真实改变主 workspace `MEMORY.md` 时发送 notice。
- notice 发送逻辑必须集中到一个 helper，不允许每个工具手写不同格式。

### 6) Observability contract

新增或扩展 observation tag：

```text
memory.refresh.job.finished
memory.refresh.job.failed
memory.write.changed
memory.notice.sent
memory.notice.skipped
```

至少记录：

- `session_key`
- `provider`
- `model`
- `model_role`
- `status`
- `summary`
- `before_hash`
- `after_hash`
- `memory_bytes`
- `notice_status`

summary 不能包含整份 memory，也不能包含未脱敏的完整对话。

## 执行顺序 / stage 依赖

- Stage 0：确认现有基线和冻结范围。
- Stage 1：配置层新增 `memory_model` role 与 fallback resolver。
- Stage 2：把所有 refresh 调用点切到 memory model runtime。
- Stage 3：扩展 refresh result 和 `save_memory.summary` contract。
- Stage 4：实现统一 memory notice helper，并接入后台 refresh。
- Stage 5：接入显式 memory tools 的 notice。
- Stage 6：文档、prompt、观测和验收收口。

Stage 1 依赖 Stage 0。
Stage 2 依赖 Stage 1。
Stage 3 依赖 Stage 2。
Stage 4 依赖 Stage 3。
Stage 5 依赖 Stage 4。
Stage 6 依赖 Stage 5。

## Stage 0

### 前置检查

- 当前工作树变更已确认，不覆盖不相关文件。
- 先读本 phase 的 finding 和上述代码路径。

### 这一步改哪里

- `docs/dev/task-plan/phase17-memory-refresh-cost-and-visibility.md`

### 这一步要做

- 确认本阶段只做：
  - memory model role
  - refresh/model call path 切换
  - memory update notice
  - observation metadata
- 明确不做：
  - threshold/gating 触发策略
  - ops-based memory merge
  - vector memory
  - per-channel memory isolation
  - undo/edit UI

### 实施注意事项

- 不要为了保留旧 tuple contract 写长期兼容分支。
- 不要把 notice 发送散落到多个工具里各自实现格式。

### 本 stage 验收

- reviewer 能从本文档确认 phase 范围和非目标。

### 本 stage 验证

- 人工检查本文档结构符合 task-plan 规范。

## Stage 1

### 前置检查

- Stage 0 完成。
- `Config.model_role/2`、`default_model_runtime/1`、`cheap_model_runtime/1`、`advisor_model_runtime/1` 当前行为已读。

### 这一步改哪里

- `lib/nex/agent/config.ex`
- `test/nex/agent/config_test.exs`
- `docs/dev/progress/CURRENT.md`（如 config contract 说明需要更新）

### 这一步要做

- 在 default config 中加入 `"memory_model"`，默认值可等于 `"cheap_model"` 当前默认。
- `normalize_model_root/1` 保留并规范化 `"memory_model"`。
- 新增 `memory_model_runtime/1`。
- 为 fallback 写测试：
  - 配了 `memory_model` 时使用它。
  - 未配 `memory_model` 但配了 `cheap_model` 时使用 cheap。
  - 两者都缺时使用 default。

### 实施注意事项

- `memory_model` 是 model role，不是 provider，也不是 tool config。
- 不要在业务模块里自己解析 raw config map。

### 本 stage 验收

- config accessor 能稳定返回完整 `%{provider, model_id, api_key, base_url, provider_options}` runtime。

### 本 stage 验证

- `mix test test/nex/agent/config_test.exs`

## Stage 2

### 前置检查

- Stage 1 完成。
- 现有 memory refresh 调用点已列全。

### 这一步改哪里

- `lib/nex/agent.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/tool/memory_consolidate.ex`
- `lib/nex/agent/tool/memory_rebuild.ex`
- `test/nex/agent/runner_evolution_test.exs`
- `test/nex/agent/inbound_worker_memory_refresh_test.exs`
- `test/nex/agent/memory_consolidate_test.exs`
- `test/nex/agent/memory_rebuild_test.exs`

### 这一步要做

- 在 runtime snapshot/config 可用的位置解析 memory model runtime。
- 自动后台 refresh enqueue 时传入 memory runtime 的 provider/model/api_key/base_url/provider_options。
- `memory_consolidate` 和 `memory_rebuild` 默认使用 memory runtime。
- 保留测试注入的 `llm_call_fun` / `req_llm_stream_text_fun`。

### 实施注意事项

- 不要让 MemoryUpdater 自己读 config 文件。
- 优先从 `runtime_snapshot.config` 或 tool ctx `config` 获取 config。
- 如果 runtime snapshot 不可用，保持现有 fallback 行为，但仍通过 `Config.default()`/agent 已有 runtime 信息走清晰路径。

### 本 stage 验收

- owner run 使用强模型回答时，memory refresh 可以使用 cheap/memory model。
- explicit `memory_consolidate` 的 LLM opts 中 model/provider 来自 memory role。

### 本 stage 验证

- `mix test test/nex/agent/config_test.exs test/nex/agent/memory_consolidate_test.exs test/nex/agent/inbound_worker_memory_refresh_test.exs test/nex/agent/runner_evolution_test.exs`

## Stage 3

### 前置检查

- Stage 2 完成。
- 所有 `Memory.refresh/4` 调用点已经可编译定位。

### 这一步改哪里

- `lib/nex/agent/memory.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/memory_updater.ex`
- `lib/nex/agent/tool/memory_consolidate.ex`
- `lib/nex/agent/tool/memory_rebuild.ex`
- `test/nex/agent/memory_consolidation_test.exs`
- `test/nex/agent/memory_updater_test.exs`
- `test/nex/agent/memory_consolidate_test.exs`
- `test/nex/agent/memory_rebuild_test.exs`

### 这一步要做

- 改 `Memory.refresh/4` 返回 `refresh_result` map。
- 扩展内部 `save_memory` tool schema，加入 `summary`。
- update/noop 路径都计算 `before_hash`、`after_hash`、`memory_bytes`。
- 更新所有调用点使用 `refresh_result.status`。
- `Memory.consolidate/4` 兼容 wrapper 也迁移到新 result shape，不保留旧 atom 分支。

### 实施注意事项

- `summary` 不参与是否写入的判断；写入判断仍以 normalized memory body 是否变化为准。
- `summary` 不应写进 `MEMORY.md`，只作为 observation/notice metadata。

### 本 stage 验收

- refresh 测试能断言 summary、hash、memory_bytes。
- `status=noop` 能推进 `last_consolidated` 但不产生 notice 候选。

### 本 stage 验证

- `mix test test/nex/agent/memory_consolidation_test.exs test/nex/agent/memory_updater_test.exs`

## Stage 4

### 前置检查

- Stage 3 完成。
- 当前 channel outbound topic 和 Bus publish contract 已读。

### 这一步改哪里

- `lib/nex/agent/memory_updater.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/outbound.ex`（如需要 helper）
- `test/nex/agent/memory_updater_test.exs`
- `test/nex/agent/inbound_worker_memory_refresh_test.exs`

### 这一步要做

- 给 `MemoryUpdater` job 增加 notice metadata：
  - `channel`
  - `chat_id`
  - `notify_memory_updates?`
  - `source`
- owner run enqueue 时传入当前 channel/chat_id。
- cron/subagent/follow-up/internal enqueue 明确关闭 notice。
- 后台 refresh result `:updated` 后调用统一 helper 发送 notice。

### 实施注意事项

- notice 必须在 final reply 之后发送，不阻塞主回复。
- `MemoryUpdater` 不能因为 notice 发送失败而回滚 memory 写入。
- notice 发送失败要写 observation，但 job result 仍以 memory refresh 成败为准。

### 本 stage 验收

- inbound final reply 先发布，memory notice 后发布。
- noop refresh 不发布 notice。
- 没有 channel/chat_id 时不崩溃，只记录 skipped。

### 本 stage 验证

- `mix test test/nex/agent/inbound_worker_memory_refresh_test.exs test/nex/agent/memory_updater_test.exs`

## Stage 5

### 前置检查

- Stage 4 完成。
- 统一 notice helper 已存在。

### 这一步改哪里

- `lib/nex/agent/tool/memory_write.ex`
- `lib/nex/agent/tool/memory_consolidate.ex`
- `lib/nex/agent/tool/memory_rebuild.ex`
- `test/nex/agent/memory_write_test.exs`
- `test/nex/agent/memory_consolidate_test.exs`
- `test/nex/agent/memory_rebuild_test.exs`
- `test/nex/agent/message_tool_test.exs`（如 outbound notice surface 需要覆盖）

### 这一步要做

- `memory_write` 成功改变 `MEMORY.md` 后发送 notice。
- `memory_consolidate` 用 refresh summary 发送 notice。
- `memory_rebuild` promote 后发送 rebuild summary notice。
- notice helper 从 ctx 读取 `channel/chat_id/session_key/workspace`。

### 实施注意事项

- `memory_status` 不能发送 notice。
- `memory_write append` 如果内容已存在且没有改变文件，不发送 notice。
- `memory_rebuild` 失败或未改变文件，不发送 notice。

### 本 stage 验收

- 所有 user-visible memory mutation 共用同一 notice 格式。
- 工具返回内容和用户 notice 不互相替代；工具结果仍供模型继续推理。

### 本 stage 验证

- `mix test test/nex/agent/memory_write_test.exs test/nex/agent/memory_consolidate_test.exs test/nex/agent/memory_rebuild_test.exs`

## Stage 6

### 前置检查

- Stage 5 完成。
- focused tests 通过。

### 这一步改哪里

- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/tool/memory_status.ex`
- `docs/dev/progress/CURRENT.md`
- `docs/dev/progress/YYYY-MM-DD.md`
- `test/nex/agent/context_builder_test.exs`
- `test/nex/agent/memory_status_test.exs`
- `test/nex/agent/tool_alignment_test.exs`

### 这一步要做

- prompt guidance 说明 memory update 会发送 notice，用户可用 `memory_status` 检查。
- `memory_status` 可选展示最近一次 memory update observation summary。
- 更新 docs/dev 当前状态和验证命令。
- 全面跑 focused tests 和 compile。

### 实施注意事项

- 不在 prompt 里鼓励每轮主动 `memory_consolidate`。
- 不把 notice 当作 memory truth source；truth source 仍是 `MEMORY.md` 和 ControlPlane observation。

### 本 stage 验收

- 用户能看到 memory update notice。
- 开发者能从 ControlPlane 查到 notice/update 元数据。
- memory refresh 默认模型由 memory role/fallback 控制。

### 本 stage 验证

- `mix test test/nex/agent/config_test.exs`
- `mix test test/nex/agent/memory_consolidation_test.exs test/nex/agent/memory_updater_test.exs`
- `mix test test/nex/agent/memory_consolidate_test.exs test/nex/agent/memory_rebuild_test.exs test/nex/agent/memory_write_test.exs test/nex/agent/memory_status_test.exs`
- `mix test test/nex/agent/inbound_worker_memory_refresh_test.exs test/nex/agent/runner_evolution_test.exs`
- `mix test test/nex/agent/context_builder_test.exs test/nex/agent/tool_alignment_test.exs`
- `mix compile`

## Review Fail 条件

- memory refresh 仍默认使用 owner run 的 expensive model。
- `memory_model` 被实现成 tool config、provider config 或散落在业务模块里的 raw map 解析。
- `Memory.refresh/4` 调用点同时支持旧 atom tuple 和新 result map，形成长期双 contract。
- `noop` refresh 发送用户 notice。
- cron、follow-up、subagent 或 silent/internal context 发送 memory notice。
- 每个 tool 自己拼 notice 文案，没有统一 helper。
- notice 内容包含整份 `MEMORY.md`、完整对话、secret 或过长 summary。
- memory update observation 缺少 provider/model/model_role 或 before/after hash。
- 为了本阶段顺手改触发频率、threshold、ops merge、向量库或 per-channel memory isolation。
