# Phase 2A Dynamic Approval Core

## 当前状态

- `read` / `write` / `edit` / `list_dir` 通过 `Nex.Agent.Sandbox.Security.validate_path/1` 做静态 allowed roots 校验。
- allowed roots 来自 `NEX_ALLOWED_ROOTS` 或 `Security.default_allowed_roots/0`，越界路径直接返回 `Security: Path not within allowed roots`。
- `bash` 只通过 `Security.validate_command/1` 做命令黑名单和危险 pattern 拦截，不走文件路径授权。
- `InboundWorker` 在 session busy 时会把普通消息排队；如果直接把 `/approve` / `/deny` 当普通消息处理，会造成 agent 等批准、批准消息进队列的死锁。
- Hermes Agent 已有危险命令 approval 体系，本 phase 对齐它的核心交互 contract，但落到 NexAgent 的 Elixir/OTP 架构。

## 完成后必须达到的结果

- 文件工具支持“静态 allowed roots + 动态用户授权”。
- 当 agent 需要访问 allowed roots 外的路径时，系统向当前 channel/chat 发送批准请求，而不是直接失败。
- 用户可以发送 `/approve`、`/approve session`、`/approve always`、`/approve all`、`/deny`、`/deny all` 解除或拒绝等待中的请求。
- `/approve` / `/deny` 必须绕过 active task 排队逻辑，不能被 busy session 卡住。
- `once` 批准只放行当前等待操作；`session` 批准只在当前 `{workspace, session_key}` 生效；`always` 批准持久化到 workspace。
- `bash` 高风险命令支持进入批准流；硬禁止命令仍然直接拒绝。
- 第一版使用纯文本批准消息，不实现平台原生按钮。

## 开工前必须先看的代码路径

- `/Users/krisxin/Desktop/hermes-agent/tools/approval.py`
- `/Users/krisxin/Desktop/hermes-agent/gateway/run.py`
- `lib/nex/agent/security.ex`
- `lib/nex/agent/tool/read.ex`
- `lib/nex/agent/tool/write.ex`
- `lib/nex/agent/tool/edit.ex`
- `lib/nex/agent/tool/list_dir.ex`
- `lib/nex/agent/tool/bash.ex`
- `lib/nex/agent/tool/message.ex`
- `lib/nex/agent/runner.ex`
- `lib/nex/agent/tool/registry.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/bus.ex`
- `lib/nex/agent/workspace.ex`
- `lib/nex/agent/application.ex`

## 固定边界 / 已冻结的数据结构与 contract

本 phase 固定以下边界。

1. 新增 `Nex.Agent.Approval` GenServer。
2. 新增 `Nex.Agent.Approval.Request` struct，字段固定为：

```elixir
%Nex.Agent.Approval.Request{
  id: String.t(),
  workspace: String.t(),
  session_key: String.t(),
  channel: String.t(),
  chat_id: String.t(),
  kind: :path | :command,
  operation: atom(),
  subject: String.t(),
  description: String.t(),
  grant_key: String.t(),
  path_info: map() | nil,
  requested_at: DateTime.t(),
  expires_at: DateTime.t() | nil,
  from: GenServer.from() | nil
}
```

3. Grant shape 固定为：

```elixir
%{
  "kind" => "path" | "command",
  "operation" => "read" | "write" | "list" | "execute",
  "subject" => String.t(),
  "grant_key" => String.t(),
  "scope" => "session" | "always",
  "created_at" => String.t()
}
```

4. 持久化文件固定为：

```text
<workspace>/permissions/approvals.json
```

文件内容固定为：

```json
{
  "version": 1,
  "grants": []
}
```

5. Grant key 生成规则固定为：
   - path grant: `path:<operation>:<canonical_path>`
   - command grant: `command:execute:<pattern_key>`
6. `always` path grant 必须基于具体 canonical path 或目录，不允许第一版自动把父目录提升成 root。
7. `session` grant key 作用域固定为 `{Path.expand(workspace), session_key, grant_key}`。
8. `Approval.request/1` contract 固定为：

```elixir
{:ok, :approved}
| {:error, :denied}
| {:error, :timeout}
| {:error, {:cancelled, :new | :stop | :shutdown | atom()}}
| {:error, String.t()}
```

9. `Security.authorize_path/3` contract 固定为：

```elixir
authorize_path(path, operation, ctx)
```

返回：

```elixir
{:ok, expanded_path}
| {:error, reason}
```

其中 `operation` 只能是 `:read`、`:write`、`:list`。

10. 新增 path canonicalization contract，`Security.authorize_path/3` 必须先调用等价 helper 生成以下 shape：

```elixir
%{
  input_path: String.t(),
  expanded_path: String.t(),
  canonical_path: String.t(),
  existing_ancestor: String.t(),
  existing_ancestor_realpath: String.t(),
  missing_suffix: [String.t()],
  target_exists?: boolean()
}
```

字段语义冻结：

- `expanded_path` 是 `Path.expand(input_path)`。
- `existing_ancestor` 是从 `expanded_path` 向上查找得到的最近存在路径。
- `existing_ancestor_realpath` 必须使用 `File.realpath/1` 或等价方式解析 symlink 后得到。
- `canonical_path` 是 `existing_ancestor_realpath` 与 `missing_suffix` 重新拼接后的真实授权目标。
- 对存在的 final target，`missing_suffix` 为空，`canonical_path` 必须等于 final target 的 realpath。
- 对不存在的 write target，`canonical_path` 必须基于最近存在祖先目录的 realpath，而不是基于用户输入字符串。

11. allowed roots 判断必须使用 `canonical_path`，并且必须是 path-boundary aware。
    - 允许：`canonical_path == root`。
    - 允许：`String.starts_with?(canonical_path, root <> "/")`。
    - 不允许：`/tmp/foo` 匹配 `/tmp/foobar`。
12. path approval 的 `subject` 和 `grant_key` 必须基于 `canonical_path`，不能基于未解析 symlink 的 `expanded_path`。
13. 对 `:write` 和 `:edit` 的不存在目标，必须用最近存在祖先目录 realpath 判定是否越界。
    - 如果 `/allowed/link_out/new.txt` 中 `link_out` 指向 `/private/outside`，最终 `canonical_path` 必须是 `/private/outside/new.txt`。
    - 该路径不在 allowed roots 时必须进入 approval，而不能因为输入 path 以 `/allowed` 开头而直接允许。
14. `bash` 的命令判断拆成两层：
    - `Security.validate_command/1` 保持硬拒绝语义。
    - 新增 `Security.command_approval_requirement/1` 返回 `:ok | {:approval_required, pattern_key, description}`。
15. session cleanup API 语义冻结：
    - `cancel_pending(workspace, session_key, reason, opts \\ []) :: non_neg_integer()` 只取消 pending approvals，不清 session grants。
    - `clear_session_grants(workspace, session_key) :: :ok` 只清 session-scoped grants，不影响 always grants。
    - `reset_session(workspace, session_key, reason) :: %{cancelled: non_neg_integer(), grants_cleared: true}` 同时取消 pending approvals 并清 session-scoped grants。
    - `clear_session/2` 不允许作为 public API 使用，避免语义混乱；如果实现者保留私有 helper，必须只在上述 API 内部调用。
16. 本 phase 不实现 LLM smart approval，不实现按钮，不实现 admin UI。

## 执行顺序 / stage 依赖

- Stage 1: 建立 Approval GenServer 和持久化 grant store。
- Stage 2: 接入 path dynamic approval。
- Stage 3: 接入 `/approve` / `/deny` slash 命令和 busy-session bypass。
- Stage 4: 接入 bash 高风险命令审批。
- Stage 5: 补齐 prompt/tool 文案、审计事件、回归测试。

Stage 2 依赖 Stage 1。  
Stage 3 依赖 Stage 1。  
Stage 4 依赖 Stage 1 和 Stage 3。  
Stage 5 依赖 Stage 2、Stage 3、Stage 4。  
当前主线从 Stage 1 开始。

## Stage 1

### 前置检查

- 确认 `Nex.Agent.App.Bus` 已启动且 channel outbound topic 可用。
- 确认 `Workspace.ensure!/1` 创建目录时不会覆盖未知目录。
- 确认 `Application` supervision tree 里新增 GenServer 的位置。

### 这一步改哪里

- 新增 `lib/nex/agent/approval.ex`
- 新增 `lib/nex/agent/approval/request.ex`
- 更新 `lib/nex/agent/application.ex`
- 更新 `lib/nex/agent/workspace.ex`
- 新增 `test/nex/agent/approval_test.exs`

### 这一步要做

- 定义 `Nex.Agent.Approval.Request` struct。
- 定义 `Nex.Agent.Approval` GenServer，启动时初始化 state：
  - `pending: %{runtime_key => :queue.queue()}`
  - `session_grants: MapSet.t()`
  - `always_grants: MapSet.t()`
- 新增 public API：
  - `request(map())`
  - `approve(workspace, session_key, choice, opts \\ [])`
  - `deny(workspace, session_key, opts \\ [])`
  - `pending?(workspace, session_key)`
  - `approved?(workspace, session_key, grant_key)`
  - `grant_session(workspace, session_key, grant_key)`
  - `grant_always(workspace, grant_map)`
  - `cancel_pending(workspace, session_key, reason, opts \\ [])`
  - `clear_session_grants(workspace, session_key)`
  - `reset_session(workspace, session_key, reason)`
- `request/1` 必须：
  - 如果已有 matching session grant 或 always grant，直接返回 `{:ok, :approved}`。
  - 否则创建 pending request，发送 outbound 文本批准请求，并阻塞等待批准结果。
  - 默认 timeout 固定为 300 秒。
  - timeout 后清理 pending entry 并返回 `{:error, :timeout}`。
- `approve/4` 必须：
  - 默认批准最老 pending request。
  - `opts[:all] == true` 时批准当前 session 全部 pending request。
  - `choice` 支持 `:once`、`:session`、`:always`。
- `deny/3` 必须：
  - 默认拒绝最老 pending request。
  - `opts[:all] == true` 时拒绝当前 session 全部 pending request。
- `cancel_pending/4` 必须：
  - 对当前 session 所有 pending request 调用 `GenServer.reply(from, {:error, {:cancelled, reason}})`。
  - 返回被取消的 request 数量。
  - 从 pending queue 和 id index 中移除被取消 request。
- `reset_session/3` 必须：
  - 先调用 `cancel_pending/4`。
  - 再清掉 `{workspace, session_key, grant_key}` 作用域的 session grants。
  - 不删除 workspace-level always grants。
- 持久化目录加入 `Workspace.known_dirs/0`，目录名固定为 `permissions`。

### 实施注意事项

- 不要用 Process dictionary 存 pending 状态。
- `request/1` 可以用 `GenServer.call/3` + 保存 caller `from` + 后续 `GenServer.reply/2` 的方式阻塞调用方。
- outbound 文本发送不要依赖 `Message` tool，直接通过 `Bus.publish/2` 发 channel topic，避免工具递归。
- 发送消息的 topic 映射与 `InboundWorker.publish_outbound/3`、`Tool.Message` 保持一致。
- pending queue 必须 FIFO。
- timeout 清理时不能误删同 session 的其他 pending request。
- 持久化文件读写必须容忍不存在、空文件、非法 JSON，并在非法 JSON 时返回空 grants 且记录日志。

### 本 stage 验收

- `Nex.Agent.Approval` 能启动并读写 `<workspace>/permissions/approvals.json`。
- 没有 pending request 时 `/approve` 相关 API 返回 0 或明确无 pending 状态。
- `request/1` 能创建 pending request 并在 `approve/4` 后恢复调用方。
- `request/1` 能在 `deny/3` 后返回拒绝。
- `cancel_pending/4` 能唤醒等待中的 request，并返回 `{:error, {:cancelled, reason}}`。
- `reset_session/3` 能取消 pending request 并清理 session grants，但不删除 always grants。
- `approve(..., :session)` 后同一 `{workspace, session_key, grant_key}` 再次请求无需等待。
- `approve(..., :always)` 后新 session 对同一 `grant_key` 也无需等待。

### 本 stage 验证

- 新增单测覆盖：
  - request pending lifecycle
  - approve once/session/always
  - deny
  - cancel_pending returns cancelled result to waiting callers
  - reset_session clears session grants and preserves always grants
  - FIFO approve
  - timeout cleanup
  - persistent grant reload
- 运行：
  - `mix test test/nex/agent/approval_test.exs`

## Stage 2

### 前置检查

- Stage 1 的 `Approval.request/1` 已能阻塞并被批准或拒绝。
- 确认 `read/write/edit/list_dir` 当前错误字符串由 Runner 转为 tool result，不会 crash 主循环。
- 确认 `ctx` 中已有 `workspace`、`session_key`、`channel`、`chat_id`。

### 这一步改哪里

- `lib/nex/agent/security.ex`
- `lib/nex/agent/tool/read.ex`
- `lib/nex/agent/tool/write.ex`
- `lib/nex/agent/tool/edit.ex`
- `lib/nex/agent/tool/list_dir.ex`
- `test/nex/agent/write_edit_tool_test.exs`
- `test/nex/agent/profile_path_guard_test.exs`
- 新增或更新 `test/nex/agent/security_approval_test.exs`

### 这一步要做

- 新增 `Security.authorize_path/3`。
- 保留 `Security.validate_path/1` 的纯路径校验能力。
- 新增或等价实现 path canonicalization helper，必须产出固定 `path_info` shape。
- `authorize_path/3` 流程固定为：
  - expand path。
  - 基于最近存在祖先目录 realpath 生成 `path_info.canonical_path`。
  - 检查 path traversal、symlink escape、allowed roots boundary。
  - 如果 `path_info.canonical_path` 在 allowed roots 内，返回 `{:ok, expanded}`。
  - 如果 ctx 缺少 `session_key`、`channel` 或 `chat_id`，返回原来的安全错误，不进入 approval。
  - 如果 canonical path 不在 allowed roots 内，构造 `Approval.Request` 并调用 `Approval.request/1`。
  - request 的 `subject` 固定为 `path_info.canonical_path`。
  - request 的 `path_info` 固定保存完整 path_info map。
  - approval 成功后返回 `{:ok, expanded}`。
  - approval 拒绝或 timeout 后返回 `{:error, "Approval denied: ..."}` 或 `{:error, "Approval timed out: ..."}`。
- `read` 使用 `authorize_path(path, :read, ctx)`。
- `write` 和 `edit` 使用 `authorize_path(path, :write, ctx)`。
- `list_dir` 使用 `authorize_path(path, :list, ctx)`。
- 保留 `workspace/memory/USER.md` reserved path guard，顺序固定为：
  - 先 path authorization。
  - 再 reserved profile guard。

### 实施注意事项

- 不要把 `NEX_ALLOWED_ROOTS` 移除；它仍然是静态白名单入口。
- dynamic approval 只在工具执行上下文明确来自用户会话时启用。
- cron 和 subagent 如果没有明确 channel/chat，不应悄悄申请授权。
- path grant 不能自动扩展成父目录授权。
- `String.starts_with?(expanded, root)` 现有实现存在 `/tmp/foo` 匹配 `/tmp/foobar` 的风险；本 stage 如果触碰 path 判断，必须改为 path-boundary aware。
- `write` / `edit` 的目标文件不存在时，不允许跳过 symlink 检查；必须检查最近存在祖先目录的 realpath。
- 对存在的 symlink final target，必须基于 target realpath 判定 allowed roots，而不是 symlink 文件本身路径。

### 本 stage 验收

- allowed roots 内的文件读写行为不变。
- allowed roots 外的文件读取会发送批准请求并等待。
- 用户批准后，原 tool call 继续并返回真实文件内容。
- 用户拒绝后，tool result 是明确拒绝，不会再次自动重试同一个操作。
- `session` / `always` grant 对文件工具生效。
- 指向 allowed roots 外的 symlink 目录下创建新文件时，必须进入 approval。
- `/tmp/foo` 不得因为 `/tmp/foobar` 是 allowed root 或相反路径前缀而误判通过。

### 本 stage 验证

- 新增或更新测试覆盖：
  - out-of-root read waits for approval
  - approve resumes read
  - deny blocks read
  - session grant skips second prompt
  - always grant survives new session
  - missing channel/chat context falls back to direct security error
  - non-existing write target under symlinked ancestor requires approval
  - existing symlink final target uses realpath for authorization
  - path-boundary check rejects prefix false positives
- 运行：
  - `mix test test/nex/agent/approval_test.exs`
  - `mix test test/nex/agent/security_approval_test.exs`
  - `mix test test/nex/agent/write_edit_tool_test.exs`
  - `mix test test/nex/agent/profile_path_guard_test.exs`

## Stage 3

### 前置检查

- Stage 1 的 `Approval.approve/4` 和 `Approval.deny/3` 已可解除 pending request。
- 明确 `InboundWorker.dispatch_inbound/2` 的 command 分支位置。
- 确认所有 channel 入站最终都会发布到 `:inbound` 并经过 `InboundWorker`。

### 这一步改哪里

- `lib/nex/agent/inbound_worker.ex`
- `test/nex/agent/inbound_worker_test.exs`
- 需要时新增 `test/nex/agent/approval_command_test.exs`

### 这一步要做

- 在 `dispatch_inbound/2` 的 `cond` 中，`active_tasks` 排队逻辑之前处理：
  - `/approve`
  - `/approve all`
  - `/approve session`
  - `/approve all session`
  - `/approve always`
  - `/approve all always`
  - `/deny`
  - `/deny all`
- slash 命令解析规则固定为：
  - 包含 `all` 就设置 `all: true`。
  - 包含 `always`、`permanent`、`permanently` 就 choice 为 `:always`。
  - 包含 `session`、`ses` 就 choice 为 `:session`。
  - 否则 `/approve` choice 为 `:once`。
  - `/deny` 不接受 session/always scope，只接受 all。
- approve 成功后向当前 channel/chat 回一条确认消息。
- deny 成功后向当前 channel/chat 回一条拒绝确认。
- 没有 pending 时返回 `No pending approval request.`。
- `/new` 和 `/stop` 时清理当前 session 的 pending approvals。
  - `/new` 固定调用 `Approval.reset_session(workspace, session_key, :new)`。
  - `/stop` 固定调用 `Approval.cancel_pending(workspace, session_key, :stop)`，不清 session grants。

### 实施注意事项

- `/approve` / `/deny` 必须不进入 `pending_queue`。
- `/approve` / `/deny` 必须不调用 LLM。
- approve/deny 回执必须使用 `publish_outbound/3`。
- 如果 active task 正在等 approval，approve 后 active task 会自己继续，不要在 slash handler 里手动触发 agent prompt。
- `/stop` 清理 pending 时，要让等待中的 request 返回 denied 或 interrupted，不能留下永久阻塞 caller。
- `/new` 清理 pending 时，要让等待中的 request 返回 `{:error, {:cancelled, :new}}`。
- `/stop` 清理 pending 时，要让等待中的 request 返回 `{:error, {:cancelled, :stop}}`。

### 本 stage 验收

- session busy 时发送 `/approve` 能立即解除 pending request。
- session busy 时发送 `/deny` 能立即解除 pending request。
- `/approve all` 能解除同 session 全部 pending request。
- `/new` / `/stop` 后 pending approval 不再悬挂。
- `/new` 会清除 session grants；`/stop` 不会清除 session grants。

### 本 stage 验证

- 新增或更新测试覆盖：
  - busy session approval bypass
  - approve command parses once/session/always/all
  - deny command parses all
  - no pending response
  - stop clears pending
  - new clears pending and session grants
  - stop preserves session grants
- 运行：
  - `mix test test/nex/agent/inbound_worker_test.exs`
  - `mix test test/nex/agent/approval_command_test.exs`

## Stage 4

### 前置检查

- Stage 3 已能从用户消息解除 pending approval。
- 确认 `bash` 的硬拒绝行为当前被测试覆盖。
- 明确哪些命令必须继续硬拒绝，哪些命令改为需要批准。

### 这一步改哪里

- `lib/nex/agent/security.ex`
- `lib/nex/agent/tool/bash.ex`
- `test/nex/agent/bash_tool_test.exs`
- `test/nex/agent/security_approval_test.exs`

### 这一步要做

- 拆分命令策略：
  - `@blocked_commands` 和真正不可执行的 shell invocation 继续走硬拒绝。
  - destructiveness / high-risk pattern 进入 approval。
- 新增 `Security.command_approval_requirement/1`。
- 第一版 approval patterns 至少覆盖：
  - `rm -rf` 或 recursive delete。
  - `git reset --hard`。
  - `git clean -f`。
  - `git push --force` / `git push -f`。
  - 写 `/etc`、`/dev/sd*`。
  - `chmod 777` 或 world-writable chmod。
  - `curl|wget ... | sh/bash`。
- `Bash.execute/2` 流程固定为：
  - `Security.validate_command(command)`。
  - `Security.authorize_command(command, ctx)` 或等价 helper。
  - `System.cmd("sh", ["-c", command], ...)`。
- `authorize_command/2` 使用 `Approval.request/1`，kind 固定为 `:command`，operation 固定为 `:execute`。
- `bash` 的 approval request description 必须包含命中的 pattern 描述和完整 command preview。

### 实施注意事项

- 不要把所有 `python -c` 这类开发命令都继续硬拒绝；如果要保守，先改成 approval required，不要直接 allow。
- 不要在 approval 后设置 `force: true` 一类绕过参数；批准只针对当前等待 request。
- command grant key 用 pattern key，不用完整 command，和 Hermes 的 session/permanent pattern allowlist 对齐。
- `always` 对 command 只批准 pattern，不批准任意命令全文。

### 本 stage 验收

- 硬禁止命令仍直接失败。
- 高风险命令在 interactive ctx 下进入 approval。
- `/approve` 后原 bash tool call 继续执行。
- `/deny` 后 bash tool call 返回明确 blocked。
- `/approve session` 后同一 pattern 本 session 不再重复询问。

### 本 stage 验证

- 新增或更新测试覆盖：
  - hard blocked command stays blocked
  - dangerous command requires approval
  - approved dangerous command executes
  - denied dangerous command returns blocked
  - session command grant skips second prompt
- 运行：
  - `mix test test/nex/agent/bash_tool_test.exs`
  - `mix test test/nex/agent/security_approval_test.exs`

## Stage 5

### 前置检查

- Stage 2、Stage 3、Stage 4 主链均已通过窄测试。
- 明确哪些用户可见文案需要出现在 tool descriptions 或 docs。

### 这一步改哪里

- `lib/nex/agent/context_builder.ex`
- `lib/nex/agent/tool/read.ex`
- `lib/nex/agent/tool/write.ex`
- `lib/nex/agent/tool/edit.ex`
- `lib/nex/agent/tool/list_dir.ex`
- `lib/nex/agent/tool/bash.ex`
- `README.md`
- `README.zh-CN.md`
- 需要时更新 `docs/dev/progress/CURRENT.md`

### 这一步要做

- 在 system/runtime prompt 中说明：
  - 文件越权或高风险命令会请求用户批准。
  - 用户拒绝后 agent 不应重复尝试同一操作。
  - `/approve session` 和 `/approve always` 的语义。
- 更新相关 tool description，避免仍声称只能 restricted to workspace。
- README Security 部分补充 dynamic approval 主链。
- 记录审计事件：
  - approval requested
  - approval approved
  - approval denied
  - approval timed out
- 审计 payload 至少包含：
  - workspace
  - session_key
  - kind
  - operation
  - subject
  - scope
  - request_id

### 实施注意事项

- 不要在用户可见文案里暴露 internal grant_key，除非 debug 或 audit。
- README 只描述已实现功能，不写 Phase 2B 的按钮能力。
- 审计事件不要记录完整 secret-like content；command subject 可以截断到 500 字符。

### 本 stage 验收

- 用户能从批准请求消息里明确知道要批准什么。
- README 与实际行为一致。
- 拒绝/超时/批准都有审计记录。
- 全部动态授权核心测试通过。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/approval_test.exs`
  - `mix test test/nex/agent/security_approval_test.exs`
  - `mix test test/nex/agent/bash_tool_test.exs`
  - `mix test test/nex/agent/inbound_worker_test.exs`
  - `mix test test/nex/agent/write_edit_tool_test.exs`
  - `mix test test/nex/agent/profile_path_guard_test.exs`

## Review Fail 条件

- `/approve` 或 `/deny` 被 active task 队列卡住。
- 文件越权仍然只能失败，不能进入用户批准流。
- `bash` 能绕过所有审批直接执行高风险命令。
- `always` grant 写到全局环境变量或进程内存，而不是 workspace 持久化文件。
- approval pending request 没有 timeout 或 `/stop` 清理。
- approval 被实现成 LLM 再问用户的普通对话，而不是工具执行层的阻塞授权。
- 阶段结束时测试处于已知红状态。
