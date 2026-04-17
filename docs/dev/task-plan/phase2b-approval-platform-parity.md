# Phase 2B Approval Platform Parity

## 当前状态

- Phase 2A 交付文本版动态授权主链。
- 用户通过 `/approve` 和 `/deny` 解除 pending approval。
- 批准请求通过普通 outbound 文本消息发送。
- Hermes Agent 在 Slack、Telegram、Discord、Feishu 等平台提供按钮化审批体验，并避免 typing/status 阻塞用户输入。

## 完成后必须达到的结果

- Telegram、Feishu、Slack、Discord 支持平台原生批准按钮。
- 按钮行为与文本命令完全等价，最终仍调用 `Nex.Agent.Approval.approve/4` 或 `Nex.Agent.Approval.deny/3`。
- 按钮审批必须绑定到原始请求发起人；channel allowlist 只是必要条件，不是充分条件。
- 按钮点击后原消息状态更新为 approved / denied / expired，避免重复点击造成重复处理。
- 文本 `/approve` / `/deny` 保持可用，作为所有平台的 fallback。
- 审批等待期间，平台 typing/status 不得阻止用户发送批准操作。

## 开工前必须先看的代码路径

- `/Users/krisxin/Desktop/hermes-agent/gateway/platforms/telegram.py`
- `/Users/krisxin/Desktop/hermes-agent/gateway/platforms/slack.py`
- `/Users/krisxin/Desktop/hermes-agent/gateway/platforms/discord.py`
- `/Users/krisxin/Desktop/hermes-agent/gateway/platforms/feishu.py`
- `lib/nex/agent/approval.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/channel/telegram.ex`
- `lib/nex/agent/channel/feishu.ex`
- `lib/nex/agent/channel/slack.ex`
- `lib/nex/agent/channel/discord.ex`
- `lib/nex/agent/channel/dingtalk.ex`

## 固定边界 / 已冻结的数据结构与 contract

本 phase 固定以下边界：

1. Phase 2A 的 `Nex.Agent.Approval` 是唯一审批真相源。
2. 平台按钮只负责 UX，不允许保存独立 approval state。
3. approval request outbound metadata shape 固定为：

```elixir
%{
  "approval_request" => true,
  "approval_id" => request.id,
  "approval_session_key" => request.session_key,
  "approval_workspace" => request.workspace,
  "approval_kind" => Atom.to_string(request.kind),
  "approval_operation" => Atom.to_string(request.operation),
  "approval_authorized_actor" => request.authorized_actor,
  "approval_buttons_allowed" => not is_nil(request.authorized_actor)
}
```

4. 新增 `Nex.Agent.Approval.MessageRef` struct，字段固定为：

```elixir
%Nex.Agent.Approval.MessageRef{
  approval_id: String.t(),
  platform: String.t(),
  chat_id: String.t(),
  message_id: String.t() | nil,
  thread_id: String.t() | nil,
  update_token: String.t() | nil,
  raw: map(),
  status: :pending | :approved | :denied | :expired | :already_resolved,
  attached_at: DateTime.t()
}
```

字段语义冻结：

- `message_id` 是该平台更新原 approval message 所需的主句柄。
- Slack 的 `message_id` 固定使用 `ts`，`thread_id` 固定使用 `thread_ts` 或 channel thread id。
- Discord 的 `message_id` 固定使用 message id，`thread_id` 固定使用 channel id 或 thread id。
- Telegram 的 `message_id` 固定使用 Telegram `message_id`。
- Feishu 的 `message_id` 固定使用可更新 card/message 的 message id。
- 平台额外字段只能放在 `raw`，不能新增平台专属 top-level state。

5. 新增 message ref API，所有按钮平台必须使用：

```elixir
Nex.Agent.Approval.attach_message_ref(approval_id, %Nex.Agent.Approval.MessageRef{})
Nex.Agent.Approval.message_ref(approval_id)
Nex.Agent.Approval.mark_message_status(approval_id, status)
```

6. 按钮 action payload 必须携带：
   - `approval_id`
   - `workspace`
   - `session_key`
   - `choice`: `once | session | always | deny`
7. 按钮 callback 最终必须走同一入口：

```elixir
Nex.Agent.Approval.resolve_by_id(approval_id, choice, opts)
```

返回 shape 固定为：

```elixir
{:ok,
 %{
   request: Nex.Agent.Approval.Request.t(),
   message_ref: Nex.Agent.Approval.MessageRef.t() | nil,
   status: :approved | :denied,
   choice: :once | :session | :always | :deny
 }}
| {:error, :not_found | :expired | :already_resolved | :unauthorized | term()}
```

如果 Phase 2A 没有实现 `resolve_by_id/3`，本 phase 第一个 stage 必须补上。

8. 按钮鉴权模型冻结为原发起人绑定：
   - `Approval.Request` 必须在 Phase 2B Stage 1 增加 `authorized_actor` 字段。
   - `authorized_actor` type 固定为 `%{"platform" => channel, "chat_id" => chat_id, "user_id" => user_id} | nil`。
   - `user_id` 必须来自原始 inbound payload 的 sender/user 字段，并通过 `metadata["user_id"]` 进入工具执行上下文。
   - callback actor 必须同时满足 channel allowlist 和 `authorized_actor.user_id` 相等。
   - 如果某平台无法可靠拿到原始 sender user id，第一版不得渲染按钮，必须降级为文本 `/approve` / `/deny`。
   - Slack / Discord 当前 `allow_from` 是 channel-level；按钮审批必须额外检查原始 user id，不能把 allowed channel 内所有成员都视为可审批。
9. actor 数据链固定为：
   - channel inbound payload 必须在 metadata 中提供 `"user_id"`，字段值为平台原始 sender/user id。
   - `InboundWorker.dispatch_async/5` 调用 `Nex.Agent.prompt/3` 时必须传入 `metadata: extract_metadata(payload)`。
   - `Nex.Agent.prompt/3` 已将 `opts[:metadata]` 放进 `Runner.run/3`，不得丢弃。
   - `Runner.build_tool_ctx/1` 必须继续把 `opts[:metadata]` 放进 tool ctx。
   - `Security.authorize_path/3` 和 `Security.authorize_command/2` 创建 `Approval.Request` 时，`authorized_actor` 固定从 `ctx[:channel]`、`ctx[:chat_id]`、`ctx[:metadata]["user_id"]` 构造。
   - 如果缺少 `metadata["user_id"]`，`authorized_actor` 必须为 nil，approval 只能走文本 fallback。
10. Stage 1 只冻结 MessageRef API 和 actor 透传，不要求真实 channel send 后自动 attach MessageRef；真实 attach 落在 Stage 2、Stage 3、Stage 4。
11. 本 phase 不改变 Phase 2A 的 slash command contract。
12. DingTalk 第一版只保持文本 fallback，除非已有稳定 interactive action 回调路径和用户级 actor。

## 执行顺序 / stage 依赖

- Stage 1: 扩展 Approval 按 id resolve、message ref API、authorized actor 数据链和 outbound metadata。
- Stage 2: Telegram inline keyboard 审批。
- Stage 3: Feishu interactive card 审批。
- Stage 4: Slack / Discord 按钮审批。
- Stage 5: 状态更新、重复点击防护、平台回归。

Stage 2、Stage 3、Stage 4 依赖 Stage 1，可独立落地。  
Stage 5 依赖至少一个按钮平台已接入。  
当前主线从 Stage 1 开始。

## Stage 1

### 前置检查

- Phase 2A 已完成，并且文本 `/approve` / `/deny` 流程稳定。
- `Approval.Request.id` 已在 pending queue 中唯一。
- 确认 outbound metadata 在各 channel `do_send/2` 中不会被丢弃。
- 确认 inbound payload 能否提供原始 sender user id。
- 确认 `Runner.build_tool_ctx/1` 当前已保留 `metadata`，不要改坏这条链。

### 这一步改哪里

- `lib/nex/agent/approval.ex`
- `lib/nex/agent/approval/request.ex`
- 新增 `lib/nex/agent/approval/message_ref.ex`
- `lib/nex/agent/tool/message.ex`
- `lib/nex/agent/inbound_worker.ex`
- `lib/nex/agent/runner.ex`
- `test/nex/agent/approval_test.exs`
- `test/nex/agent/inbound_worker_test.exs`
- 需要时更新 `test/nex/agent/tool_alignment_test.exs`

### 这一步要做

- 新增 `Approval.resolve_by_id/3`：
  - `resolve_by_id(id, :once, opts)`
  - `resolve_by_id(id, :session, opts)`
  - `resolve_by_id(id, :always, opts)`
  - `resolve_by_id(id, :deny, opts)`
- `resolve_by_id/3` 必须只解除对应 request，不影响同 session 其他 pending request。
- `resolve_by_id/3` 必须执行 actor 鉴权：
  - `opts[:actor]` 必须包含 platform/chat_id/user_id。
  - `opts[:actor]` 必须匹配 request.authorized_actor。
  - 平台 channel allowlist 校验必须先通过。
- 新增 `Approval.MessageRef` struct。
- 新增 `attach_message_ref/2`、`message_ref/1`、`mark_message_status/2`。
- `resolve_by_id/3` 返回值必须包含 `message_ref`，让 callback handler 更新原消息状态。
- `Approval.Request` 增加 `authorized_actor` 字段。
- `InboundWorker.dispatch_async/5` 调用 `state.agent_prompt_fun` 时必须增加 `metadata: extract_metadata(payload)`。
- `Runner.build_tool_ctx/1` 必须继续把 `opts[:metadata]` 放进 tool ctx；如果已有实现满足，只增加回归测试即可。
- `Approval.Request.authorized_actor` 固定从 tool ctx 构造：

```elixir
case {ctx[:channel], ctx[:chat_id], get_in(ctx, [:metadata, "user_id"])} do
  {channel, chat_id, user_id}
  when is_binary(channel) and channel != "" and
       is_binary(chat_id) and chat_id != "" and
       is_binary(user_id) and user_id != "" ->
    %{"platform" => channel, "chat_id" => chat_id, "user_id" => user_id}

  _ ->
    nil
end
```

- approval request outbound metadata 加入固定 shape。
- 当 `authorized_actor` 为 nil 时，outbound metadata 必须包含 `"approval_buttons_allowed" => false`。
- `Approval.request/1` 的文本消息保留 `/approve` fallback，同时 metadata 标记为 approval request。
- 增加 `Approval.get_pending_by_id/1` 或等价查询函数，供 channel callback 验证 request 是否仍有效。

### 实施注意事项

- `resolve_by_id/3` 必须处理 expired / missing / already resolved。
- 缺失 request 时返回明确错误，不要 fallback 到 FIFO approve。
- 不要让 channel 模块直接操作 pending queue。
- 不能在 Telegram/Slack/Discord/Feishu 各自保存一份独立 pending approval map。
- Stage 1 不能要求真实 channel send 自动 attach MessageRef，因为 message id / ts / card id 只有各平台发送路径才拿得到。
- 不能把 message id、ts、callback token 只存在 channel process state；平台 stage 必须通过 `attach_message_ref/2` 回写到 Approval。
- 如果 request 缺少 `authorized_actor.user_id`，按钮平台不得渲染按钮。
- 文本 `/approve` / `/deny` 不要求 user_id，仍按 Phase 2A 的 slash command contract 工作。

### 本 stage 验收

- 文本审批行为不变。
- 可以通过 approval id 精确批准或拒绝指定 request。
- 多 pending request 场景下，按钮批准不会误批准队首以外的请求。
- `attach_message_ref/2` 直接调用后，Approval state 中能查到对应 `MessageRef`。
- `resolve_by_id/3` 能返回 `message_ref`。
- 非原始发起人 actor 调用 `resolve_by_id/3` 返回 `{:error, :unauthorized}`。
- `InboundWorker.dispatch_async/5` 能把 inbound metadata 传到 `Nex.Agent.prompt/3`。
- tool ctx 中存在 `metadata["user_id"]` 时，创建的 approval request 带 `authorized_actor`。
- tool ctx 中缺少 `metadata["user_id"]` 时，创建的 approval request `authorized_actor` 为 nil，并且按钮 metadata 标记为不可用。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/approval_test.exs`
  - `mix test test/nex/agent/inbound_worker_test.exs`

## Stage 2

### 前置检查

- Stage 1 的 `resolve_by_id/3` 已稳定。
- 确认 Telegram 当前 outbound 支持 metadata 或可扩展 `sendMessage` params。
- 确认 Telegram callback query update 已能进入 channel process，或本 stage 先补 callback query 处理。

### 这一步改哪里

- `lib/nex/agent/channel/telegram.ex`
- `test/nex/agent/channel_telegram_test.exs`

### 这一步要做

- 当 outbound metadata 包含 `"approval_request" => true` 时，发送 inline keyboard。
- 只有 metadata 中 `"approval_buttons_allowed" == true` 时才发送 inline keyboard。
- 发送成功后从 Telegram API response 解析 `message_id`，调用 `Approval.attach_message_ref/2`。
- 按钮至少包含：
  - Approve Once
  - Approve Session
  - Approve Always
  - Deny
- callback data 编码固定包含 `approval_id` 和 `choice`。
- 收到 callback 后：
  - 校验 callback 来源仍满足 Telegram `allow_from`。
  - 从 callback sender 构造 actor。
  - 调用 `Approval.resolve_by_id/3`，并传入 actor。
  - 回答 callback query。
  - 使用返回的 `message_ref.message_id` 更新原消息文本或 markup，显示已批准/已拒绝/已过期。
- 失败时提示用户使用 `/approve` 或 `/deny` fallback。

### 实施注意事项

- callback data 有长度限制，必要时只放短 id 和 choice，其余通过 Approval state 查。
- 不要把完整 path 或 command 放进 callback data。
- 处理重复点击时必须幂等。
- 如果 Telegram send response 中没有 `message_id`，不要渲染按钮；发送纯文本 fallback。
- Telegram `allow_from` 通过后仍必须检查 actor user id 是否等于 request.authorized_actor.user_id。
- 如果 `"approval_buttons_allowed" != true`，发送纯文本 fallback，不附带 buttons。

### 本 stage 验收

- Telegram 上 approval request 展示按钮。
- 点击 Approve Once 后原等待 tool 继续执行。
- 点击 Deny 后原等待 tool 返回 blocked。
- 重复点击不会重复 resolve。
- 非原始发起人点击按钮会被拒绝。
- 原 approval message 能更新为 approved / denied / expired。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/channel_telegram_test.exs`
  - `mix test test/nex/agent/approval_test.exs`

## Stage 3

### 前置检查

- Stage 1 的 `resolve_by_id/3` 已稳定。
- 确认 Feishu 当前已有 interactive card 发送和 update 能力。
- 确认 Feishu callback 事件能路由到 channel process。

### 这一步改哪里

- `lib/nex/agent/channel/feishu.ex`
- `test/nex/agent/channel_feishu_test.exs`

### 这一步要做

- 当 outbound metadata 包含 `"approval_request" => true` 时，发送 Feishu interactive card。
- 只有 metadata 中 `"approval_buttons_allowed" == true` 时才发送 interactive card。
- 发送成功后拿到可更新 card/message 的 message id，调用 `Approval.attach_message_ref/2`。
- card 内容必须展示：
  - operation
  - subject preview
  - description
  - `/approve` fallback 文案
- card actions 至少包含：
  - Approve Once
  - Approve Session
  - Approve Always
  - Deny
- action callback 构造 actor 并调用 `Approval.resolve_by_id/3`。
- callback 后使用返回的 `message_ref.message_id` 更新 card 状态为 approved / denied / expired。

### 实施注意事项

- Feishu card action value 不要携带完整 subject。
- 如果当前 chat type 是 group，callback 鉴权要沿用现有 `allow_from` 逻辑，且必须匹配 request.authorized_actor.user_id，不能让任意群成员审批。
- 发送 card 失败时必须回退到纯文本 approval request。
- 发送 card 成功但拿不到 message id 时必须回退到纯文本 approval request，或发送不可更新 card 且不宣称支持状态更新。
- 如果 `"approval_buttons_allowed" != true`，发送纯文本 fallback，不附带 actions。

### 本 stage 验收

- Feishu 上 approval request 展示 interactive card。
- 点击按钮后 waiting tool 能恢复或拒绝。
- 文本 `/approve` / `/deny` fallback 仍可用。
- 非原始发起人点击按钮会被拒绝。
- card 能更新为 approved / denied / expired。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/channel_feishu_test.exs`
  - `mix test test/nex/agent/approval_test.exs`

## Stage 4

### 前置检查

- Stage 1 的 `resolve_by_id/3` 已稳定。
- 确认 Slack / Discord 当前 inbound callback 或 interaction 处理能力。
- 如果某个平台没有 callback 基础设施，本 stage 先实现最小 callback 路由，不做额外 UI 改造。

### 这一步改哪里

- `lib/nex/agent/channel/slack.ex`
- `lib/nex/agent/channel/discord.ex`
- 需要时新增：
  - `test/nex/agent/channel_slack_test.exs`
  - `test/nex/agent/channel_discord_test.exs`

### 这一步要做

- Slack:
  - 当 metadata 中 `"approval_buttons_allowed" == true` 时，approval outbound 使用 Block Kit actions。
  - 发送成功后保存 Slack `ts` 到 `MessageRef.message_id`，保存 `thread_ts` 到 `MessageRef.thread_id`。
  - action id 或 value 包含 `approval_id` 与 `choice`。
  - callback 构造 actor 并调用 `Approval.resolve_by_id/3`。
- Discord:
  - 当 metadata 中 `"approval_buttons_allowed" == true` 时，approval outbound 使用 message components。
  - 发送成功后保存 Discord message id 到 `MessageRef.message_id`，保存 channel/thread id 到 `MessageRef.thread_id`。
  - component custom id 包含 `approval_id` 与 `choice`。
  - interaction callback 构造 actor 并调用 `Approval.resolve_by_id/3`。
- 两个平台都必须保留文本 fallback。

### 实施注意事项

- Slack assistant typing/status 如果会阻止用户输入，approval request 发送前必须暂停或清理 status。
- Discord interaction ack 必须及时返回，长操作只做 resolve，不等待工具最终结果。
- 对不支持按钮的运行模式，明确降级为文本 approval。
- Slack / Discord 当前 `allow_from` 是 channel-level，按钮 callback 必须额外比较原始 request actor user id。
- 如果 Slack / Discord 无法拿到原始 sender user id 或 callback user id，第一版不得启用按钮。
- 如果 `"approval_buttons_allowed" != true`，发送纯文本 fallback，不附带 buttons/components。

### 本 stage 验收

- Slack / Discord approval request 有按钮。
- 按钮点击能解除对应 pending request。
- unauthorized click 被拒绝且不影响 pending request。
- Slack / Discord 能更新原消息状态。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/channel_slack_test.exs`
  - `mix test test/nex/agent/channel_discord_test.exs`
  - `mix test test/nex/agent/approval_test.exs`

## Stage 5

### 前置检查

- 至少 Telegram 或 Feishu 已完成按钮审批。
- 文本 fallback 已确认不回归。
- 审计事件已能区分 text approval 和 button approval。

### 这一步改哪里

- `lib/nex/agent/approval.ex`
- `lib/nex/agent/audit.ex`
- 已接入按钮的平台 channel 文件
- `README.md`
- `README.zh-CN.md`
- 相关 channel 测试

### 这一步要做

- 增加重复点击防护：
  - resolved request id 记录短期 TTL。
  - 重复 resolve 返回 `{:error, :already_resolved}`。
- 审计事件增加 `source`：
  - `slash`
  - `button`
  - `timeout`
  - `stop`
- README Security 部分补充按钮审批能力和 fallback。
- 对所有接入按钮的平台补齐：
  - expired 状态展示。
  - already resolved 状态展示。
  - unauthorized click 展示。
  - message ref missing 时的 fallback 展示。

### 实施注意事项

- resolved request TTL 不要无限增长内存。
- 不要因为按钮平台失败而破坏纯文本批准。
- 文档只描述已经实现的平台。

### 本 stage 验收

- 按钮和文本 approval 都走同一个 Approval 状态机。
- 重复点击和过期点击不会改变已决结果。
- 用户可见状态清楚区分 approved / denied / expired / already resolved。
- 每个平台更新原消息时都通过 `MessageRef` 获取句柄，不读取平台私有 pending state。

### 本 stage 验证

- 运行：
  - `mix test test/nex/agent/approval_test.exs`
  - `mix test test/nex/agent/channel_telegram_test.exs`
  - `mix test test/nex/agent/channel_feishu_test.exs`
  - 已新增 Slack / Discord 测试文件

## Review Fail 条件

- 平台按钮保存自己的审批状态，绕过 `Nex.Agent.Approval`。
- 平台发送 approval message 后没有通过 `attach_message_ref/2` 保存更新句柄。
- Stage 1 把真实平台 send 后 attach 当作验收项，导致没有平台发送句柄时无法落地。
- `InboundWorker.dispatch_async/5` 没有把 inbound metadata 传到 `Nex.Agent.prompt/3`。
- 平台各自发明 message id / ts / card id 存储结构，而不是使用 `MessageRef`。
- 按钮点击批准了错误的 pending request。
- unauthorized 用户能审批高风险操作。
- Slack / Discord 只检查 channel allowlist 就允许按钮审批。
- request 缺少原始 sender user id 时仍渲染按钮。
- 文本 `/approve` / `/deny` fallback 被破坏。
- 重复点击造成多次 approve 或 deny。
- approval request 按钮包含完整敏感 path 或 command。
- 阶段结束时测试处于已知红状态。
