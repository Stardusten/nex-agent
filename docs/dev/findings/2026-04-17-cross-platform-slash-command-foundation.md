# 2026-04-17 Cross-Platform Slash Command Foundation

## 结论

slash command 必须是独立于 tool/skill 的用户控制层。

- tool registry 是模型能力真相源，不是用户命令真相源
- channel 原生交互能力只是 command catalog 的平台投影，不拥有命令语义
- 没有原生 slash UI 的平台必须继续支持文本 `/command` fallback
- 未注册的 slash-prefixed 文本必须保持原样进入 LLM，不能被框架抢占

## 当前落地边界

新增统一 command catalog：

- `Nex.Agent.Conversation.Command.Catalog`
- `Nex.Agent.Conversation.Command.Parser`
- `Nex.Agent.Conversation.Command.Invocation`
- `Nex.Agent.Conversation.Command`

runtime snapshot 新增 `commands` 字段，command definitions 进入统一 runtime 真相源。

当前 catalog 只收敛：

- `/new`
- `/stop`
- `/commands`

## 主链执行位置

command 最终执行边界在 `InboundWorker.dispatch_inbound/2`，原因：

- session busy / queue / stop / reset 语义都在 `InboundWorker`
- `/new` `/stop` 这类命令本来就需要绕过 busy queue
- 如果把命令执行散到 channel，会重复实现 session 控制逻辑

执行顺序固定为：

1. channel 产出 `Envelope`
2. 如果是平台原生命令，可直接填 `Envelope.command`
3. `InboundWorker` 先尝试 resolve command
4. 命中 catalog 则执行统一 handler
5. 未命中则把原始文本继续走普通 LLM 主链

## 为什么不复用 Tool.Registry

- tool 是 assistant 发起
- command 是 user 发起
- tool schema 关心 `input_schema`
- command schema 关心 `usage`、`bypass_busy?`、`native_enabled?`
- 两者生命周期和权限语义不同，混在一起会破坏分层

## 平台投影原则

channel 只做 projection，不做 command state。

- Discord native application commands 之后应由 channel 基于 runtime command catalog 做注册/更新
- `INTERACTION_CREATE` 只负责转成统一 `Invocation`
- 真正执行仍回到 `InboundWorker`

因此后续 Discord autocomplete / slash registration 应建立在 runtime `snapshot.commands` 上，而不是另建一套 channel-private command list。

## 已验证 contract

- 已注册 `/commands` 不进入 LLM
- 已注册 `/new` 不进入 LLM
- 未注册 `/code keep this literal` 保持原样进入 LLM

## 后续工作

- 把 `/approve` `/deny` 收编到统一 command catalog
- 让 runtime reconcile 驱动 Discord command sync
- 为 Discord 增加 native interaction adapter 和 autocomplete handler
